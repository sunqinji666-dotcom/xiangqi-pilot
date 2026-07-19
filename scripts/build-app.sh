#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
module_cache="${TMPDIR:-/private/tmp}/xiangqi-pilot-module-cache"
clang_cache="${TMPDIR:-/private/tmp}/xiangqi-pilot-clang-cache"
app_dir="$project_root/dist/棋局驾驶舱.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
bundle_identifier="com.jacksun.xiangqi-pilot"
identity_name="${XIANGQI_CODE_SIGN_IDENTITY:-Xiangqi Pilot Local Signing}"

cd "$project_root"
DEVELOPER_DIR="$developer_dir" \
SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
CLANG_MODULE_CACHE_PATH="$clang_cache" \
swift build -c release --disable-sandbox

mkdir -p "$macos_dir" "$contents_dir/Resources"
install -m 755 ".build/arm64-apple-macosx/release/XiangqiPilot" "$macos_dir/XiangqiPilot"
install -m 644 "Packaging/Info.plist" "$contents_dir/Info.plist"
install -m 644 "THIRD_PARTY_NOTICES.md" "$contents_dir/Resources/THIRD_PARTY_NOTICES.md"

pikafish_source="$project_root/Vendor/Pikafish"
pikafish_destination="$contents_dir/Resources/Engines"
if [[ -x "$pikafish_source/pikafish" ]]; then
    mkdir -p "$pikafish_destination"
    install -m 755 "$pikafish_source/pikafish" "$pikafish_destination/pikafish"
    for network in "$pikafish_source"/*.nnue(N); do
        install -m 644 "$network" "$pikafish_destination/${network:t}"
    done
    for notice in "$pikafish_source/Copying.txt" "$pikafish_source/NNUE-License.md"; do
        [[ -f "$notice" ]] && install -m 644 "$notice" "$pikafish_destination/${notice:t}"
    done
fi

identity_hash="$(
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -v token="$identity_name" 'index($0, token) { print $2; exit }'
)"

if [[ -z "$identity_hash" ]]; then
    echo "缺少稳定的代码签名身份：$identity_name" >&2
    echo "请先运行 scripts/setup-local-signing.sh。为避免反复丢失 macOS 授权，本项目不再自动使用 ad-hoc 签名。" >&2
    exit 2
fi

designated_requirement="identifier \"$bundle_identifier\" and certificate leaf = H\"$identity_hash\""

if [[ -x "$pikafish_destination/pikafish" ]]; then
    codesign \
        --force \
        --sign "$identity_hash" \
        --options runtime \
        --timestamp=none \
        "$pikafish_destination/pikafish"
fi

codesign \
    --force \
    --sign "$identity_hash" \
    --identifier "$bundle_identifier" \
    --requirements "=designated => $designated_requirement" \
    --options runtime \
    --timestamp=none \
    "$app_dir"

codesign --verify --strict --verbose=2 "$app_dir"
codesign --verify --strict --requirements "$designated_requirement" "$app_dir"

echo "签名身份：$identity_name ($identity_hash)"
echo "$app_dir"
