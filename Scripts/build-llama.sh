#!/bin/bash
# Adapted from DigUp (https://github.com/ARahim3/DigUp, MIT; see codiclens/digup-license.txt).
#
# Builds llama.cpp (MIT), the runtime search by meaning embeds with, for arm64 with Metal: the pinned tag below plus
# Scripts/llama.cpp-no-logits.patch, as static libraries combined into Vendor/llama/lib/libllamacpp.a, with the headers
# in Vendor/llama/include. Vendor/ is not in git. The Metal shader source is embedded in the library and compiled on
# first use, so the app bundle needs no .metallib and the build needs no Metal toolchain.
#
# Run it once from anywhere before building the app; the Xcode build stops with a message naming this script while
# the headers are missing. It does nothing when the build is already there, and builds again when TAG or the patch
# changes. Needs cmake on PATH (brew install cmake).
set -euo pipefail
cd "$(dirname "$0")/.."

# b11567 (2026-10-12) is the newest release; EmbeddingGemma 2 (arch gemma-embedding2, text + vision + audio) arrived
# in b11452, which is exactly PR #30054's merge commit 4fbc76d. Bumping it can move every vector a little: the
# integration test in EmbedderIntegrationTests is the check.
TAG=b11567
COMMIT=972b5fcc19670e597f8de9bf5cacfb85752a5fff
PATCH=Scripts/llama.cpp-no-logits.patch
SOURCE=Vendor/llama.cpp
BUILD=Vendor/llama-build
OUT=Vendor/llama
STAMP="$TAG $(shasum -a 256 "$PATCH" | cut -c1-12)"

if [[ -f "$OUT/include/llama-build.h" && -f "$OUT/lib/libllamacpp.a" && "$(cat "$OUT/BUILD" 2>/dev/null)" == "$STAMP" ]]; then
  echo "llama.cpp $TAG is already built in $OUT"
  exit 0
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v cmake > /dev/null || { echo "error: cmake is not on PATH (brew install cmake)" >&2; exit 1; }

if [[ ! -d "$SOURCE/.git" ]]; then
  rm -rf "$SOURCE"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$SOURCE"
elif [[ "$(git -C "$SOURCE" rev-parse HEAD)" != "$COMMIT" ]]; then
  git -C "$SOURCE" fetch --quiet --depth 1 origin tag "$TAG"
  git -C "$SOURCE" checkout --quiet --force "$TAG"   # --force also drops an older patch
fi
# A tag can be moved; the commit cannot.
if [[ "$(git -C "$SOURCE" rev-parse HEAD)" != "$COMMIT" ]]; then
  echo "error: llama.cpp $TAG is not commit $COMMIT" >&2
  exit 1
fi
# Without the patch an embedding context reserves, and clears, one row of logits per input token that the model never
# produces: 262,144 floats (1 MiB) each with Gemma's vocabulary, so 2 GiB for one 2,048-token input.
git -C "$SOURCE" checkout --quiet -- src/llama-context.cpp
git -C "$SOURCE" apply "$PWD/$PATCH"

# Only the libraries: no tools, no server, nothing downloaded at build time. The deployment target is the app's.
cmake -S "$SOURCE" -B "$BUILD" -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.4 \
  -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DLLAMA_BUILD_MTMD=ON \
  -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF > /dev/null
cmake --build "$BUILD" --config Release -j "$(sysctl -n hw.ncpu)" --target llama mtmd > /dev/null

# The headers go in last: Codiclens's build checks for llama-build.h, so a build that stopped halfway is not mistaken
# for a finished one.
rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
xcrun libtool -static -no_warning_for_no_symbols -o "$OUT/lib/libllamacpp.a" \
  "$BUILD/src/libllama.a" "$BUILD/tools/mtmd/libmtmd.a" "$BUILD/ggml/src/libggml.a" "$BUILD/ggml/src/libggml-base.a" \
  "$BUILD/ggml/src/libggml-cpu.a" "$BUILD/ggml/src/ggml-metal/libggml-metal.a" \
  "$BUILD/ggml/src/ggml-blas/libggml-blas.a" "$BUILD/vendor/hash/libvendor-hash.a"
cp "$SOURCE/include/llama.h" "$SOURCE"/ggml/include/*.h "$SOURCE/tools/mtmd/mtmd.h" "$SOURCE/tools/mtmd/mtmd-helper.h" \
  "$OUT/include/"
printf '// Written by Scripts/build-llama.sh.\n#define LLAMA_BUILD_TAG "%s"\n' "$TAG" > "$OUT/include/llama-build.h"
echo "$STAMP" > "$OUT/BUILD"
echo "Built llama.cpp $TAG (patched) into $OUT"
