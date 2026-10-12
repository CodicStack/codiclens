// The one header Swift sees of llama.cpp. Vendor/ is not in git: Scripts/build-llama.sh writes it, last of all
// llama-build.h, so a missing or half-finished build stops here with what to do about it.
#if !__has_include("../Vendor/llama/include/llama-build.h")
#error "llama.cpp is not built. Run Scripts/build-llama.sh once from the repository root, then build again (see AGENTS.md, Build)."
#endif

#include "../Vendor/llama/include/llama-build.h"
#include "../Vendor/llama/include/llama.h"
#include "../Vendor/llama/include/mtmd.h"
