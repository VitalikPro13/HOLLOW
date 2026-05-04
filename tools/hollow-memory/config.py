from pathlib import Path

PROJECT_ROOT = Path("C:/Users/Jabun/Documents/Coding/HOLLOW")
TOOL_DIR = Path(__file__).parent

# Sources to index
MEMORY_DIR = Path("C:/Users/Jabun/.claude/projects/C--Users-Jabun-Documents-Coding-HOLLOW/memory")
HOLLOW_PLAN_PATH = PROJECT_ROOT / "HOLLOW_PLAN.md"
WHITEPAPER_PATH = PROJECT_ROOT / "WHITEPAPER.md"
CLAUDE_MD_PATH = PROJECT_ROOT / "CLAUDE.md"
WIKI_DIR = PROJECT_ROOT / "tools" / "hollow-memory" / "wiki"

# Model paths
MODELS_DIR = TOOL_DIR / "models"
ONNX_MODEL_PATH = MODELS_DIR / "onnx" / "model_O4.onnx"
TOKENIZER_PATH = MODELS_DIR / "tokenizer.json"

# Database
DB_PATH = TOOL_DIR / "hollow_memory.db"

# Embedding config
EMBEDDING_DIM = 384
MAX_TOKENS = 128

# HuggingFace model ID
HF_MODEL_ID = "sentence-transformers/all-MiniLM-L6-v2"
