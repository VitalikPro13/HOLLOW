import sys
import threading
import time

import numpy as np

from config import IDLE_UNLOAD_SECS, MAX_SEQ_TOKENS, MODEL_ID

_model = None
_device = None
_last_used = 0.0
_lock = threading.RLock()


def _load():
    global _model, _device
    import torch
    from sentence_transformers import SentenceTransformer

    _device = "cuda" if torch.cuda.is_available() else "cpu"
    kwargs = {"model_kwargs": {"torch_dtype": torch.float16}} if _device == "cuda" else {}
    t = time.time()
    _model = SentenceTransformer(MODEL_ID, device=_device, processor_kwargs={"padding_side": "left"}, **kwargs)
    _model.max_seq_length = MAX_SEQ_TOKENS
    print(f"hollow-memory: {MODEL_ID} on {_device} in {time.time() - t:.1f}s", file=sys.stderr)


def _unload_when_idle():
    global _model
    while True:
        time.sleep(60)
        with _lock:
            if _model is not None and time.time() - _last_used > IDLE_UNLOAD_SECS:
                _model = None
                if _device == "cuda":
                    import torch
                    torch.cuda.empty_cache()


threading.Thread(target=_unload_when_idle, daemon=True).start()


def embed(texts: list[str], prompt: str = "") -> np.ndarray:
    """Normalized float32 vectors; queries pass their instruction prompt, documents none."""
    global _last_used
    with _lock:
        if _model is None:
            _load()
        _last_used = time.time()
        batch = 8
        while True:
            try:
                vecs = _model.encode([prompt + t for t in texts], batch_size=batch, normalize_embeddings=True,
                                     convert_to_numpy=True, show_progress_bar=False)
                break
            except RuntimeError as e:
                if "out of memory" not in str(e).lower() or batch == 1:
                    raise
                import torch
                torch.cuda.empty_cache()
                batch //= 2
        _last_used = time.time()
        return vecs.astype(np.float32)
