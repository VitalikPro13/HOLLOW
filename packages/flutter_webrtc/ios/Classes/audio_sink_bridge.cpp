// Forwarder to the shared darwin implementation.
// Upstream uses a symlink here, but symlinks don't survive a Windows checkout
// (they get flattened to a text file containing the path, which then fails to
// compile). A relative #include works identically on Windows, macOS and iOS.
#include "../../common/darwin/Classes/audio_sink_bridge.cpp"
