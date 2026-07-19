#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
module_cache="${TMPDIR:-/private/tmp}/xiangqi-pilot-test-module-cache"
clang_cache="${TMPDIR:-/private/tmp}/xiangqi-pilot-test-clang-cache"

cd "$project_root"
DEVELOPER_DIR="$developer_dir" \
SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
CLANG_MODULE_CACHE_PATH="$clang_cache" \
swift test --disable-sandbox
