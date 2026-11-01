#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/build-env.sh
mkdir -p .build/native-src build/helpers
if ! command -v cmake >/dev/null; then
  if [ ! -x .build/build-tools/bin/cmake ]; then
    python3 -m venv .build/build-tools
    .build/build-tools/bin/pip install cmake
  fi
  CMAKE="$PWD/.build/build-tools/bin/cmake"
else
  CMAKE="$(command -v cmake)"
fi
build_one() {
  local repo="$1" tag="$2" target="$3"
  local src="$PWD/.build/native-src/$repo-$tag"
  if [ ! -d "$src" ]; then
    curl -fL --retry 3 "https://github.com/ggml-org/$repo/archive/refs/tags/$tag.tar.gz" -o ".build/native-src/$repo-$tag.tar.gz"
    mkdir -p "$src"
    tar -xzf ".build/native-src/$repo-$tag.tar.gz" -C "$src" --strip-components=1
  fi
  "$CMAKE" -S "$src" -B "$src/out-xcode27-macos26-arm64" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_SYSROOT="$MNT_MACOS_SDK" -DCMAKE_C_COMPILER="$MNT_CC" -DCMAKE_CXX_COMPILER="$MNT_CXX" -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_OSX_ARCHITECTURES=arm64 -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DWHISPER_BUILD_TESTS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_SERVER=ON
  "$CMAKE" --build "$src/out-xcode27-macos26-arm64" --config Release --target "$target" -j "${CMAKE_BUILD_PARALLEL_LEVEL:-6}"
  cp "$src/out-xcode27-macos26-arm64/bin/$target" "build/helpers/$target"
  mkdir -p build/licenses
  cp "$src/LICENSE" "build/licenses/$repo-LICENSE"
}
build_one whisper.cpp v1.9.1 whisper-cli
build_one llama.cpp b9878 llama-server

"$CMAKE" -S Sources/WhisperWorker -B .build/whisper-worker-xcode27-macos26-arm64 -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_SYSROOT="$MNT_MACOS_SDK" -DCMAKE_C_COMPILER="$MNT_CC" -DCMAKE_CXX_COMPILER="$MNT_CXX" -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_OSX_ARCHITECTURES=arm64 -DWHISPER_SOURCE="$PWD/.build/native-src/whisper.cpp-v1.9.1"
"$CMAKE" --build .build/whisper-worker-xcode27-macos26-arm64 --target whisper-worker -j "${CMAKE_BUILD_PARALLEL_LEVEL:-6}"
cp .build/whisper-worker-xcode27-macos26-arm64/whisper-worker build/helpers/whisper-worker
