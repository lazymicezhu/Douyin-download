#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc -parse-as-library -module-cache-path build/ModuleCache.noindex \
  DouyinLite/Core/TikHub.swift DouyinLite/Core/VideoDownloader.swift DouyinLite/Core/ImageDownloader.swift tests/CoreTests.swift \
  -o build/core-tests
./build/core-tests "$@"
