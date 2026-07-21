#!/bin/zsh
set -euo pipefail

identity_name="${XIANGQI_LOCAL_SIGNING_NAME:-Xiangqi Pilot Dedicated Signing}"
support_dir="${XIANGQI_SIGNING_SUPPORT_DIR:-$HOME/Library/Application Support/XiangqiPilot}"
keychain_path="${XIANGQI_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/xiangqi-pilot-signing.keychain-db}"
password_file="${XIANGQI_SIGNING_PASSWORD_FILE:-$support_dir/signing-keychain-password}"

mkdir -p "$support_dir" "${keychain_path:h}"
chmod 700 "$support_dir"

if [[ ! -f "$password_file" ]]; then
    umask 077
    openssl rand -hex 32 > "$password_file"
fi
chmod 600 "$password_file"
keychain_password="$(<"$password_file")"

if [[ ! -f "$keychain_path" ]]; then
    security create-keychain -p "$keychain_password" "$keychain_path"
fi

security unlock-keychain -p "$keychain_password" "$keychain_path"
# Keep the dedicated keychain available for a normal development day.  The
# build script also unlocks it explicitly, so a reboot never needs user input.
security set-keychain-settings -lut 86400 "$keychain_path"

current_keychains=("${(@f)$(security list-keychains -d user | tr -d '"' | sed 's/^[[:space:]]*//')}")
if (( ${current_keychains[(I)$keychain_path]} == 0 )); then
    security list-keychains -d user -s "$keychain_path" "${current_keychains[@]}"
fi

identity_hash="$({
    security find-identity -v -p codesigning "$keychain_path" 2>/dev/null \
        | awk -v label="$identity_name" 'index($0, "\"" label "\"") { print $2; exit }'
} || true)"

if [[ -z "$identity_hash" ]]; then
    umask 077
    temporary_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/xiangqi-pilot-dedicated-signing.XXXXXX")"
    private_key="$temporary_dir/signing.key"
    certificate="$temporary_dir/signing.crt"
    archive="$temporary_dir/signing.p12"
    archive_password="$(openssl rand -hex 32)"

    cleanup() {
        /bin/rm -rf -- "$temporary_dir"
    }
    trap cleanup EXIT INT TERM

    openssl req \
        -x509 \
        -newkey rsa:3072 \
        -sha256 \
        -nodes \
        -days 3650 \
        -subj "/CN=$identity_name/O=Jacksun Local Development" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -keyout "$private_key" \
        -out "$certificate"

    openssl pkcs12 \
        -export \
        -inkey "$private_key" \
        -in "$certificate" \
        -name "$identity_name" \
        -passout "pass:$archive_password" \
        -out "$archive"

    security import "$archive" \
        -k "$keychain_path" \
        -P "$archive_password" \
        -x \
        -T /usr/bin/codesign

    security set-key-partition-list \
        -S apple-tool:,apple:,codesign: \
        -s \
        -k "$keychain_password" \
        "$keychain_path"

    security add-trusted-cert \
        -r trustRoot \
        -p codeSign \
        -k "$keychain_path" \
        "$certificate"

    identity_hash="$({
        security find-identity -v -p codesigning "$keychain_path" 2>/dev/null \
            | awk -v label="$identity_name" 'index($0, "\"" label "\"") { print $2; exit }'
    } || true)"
fi

if [[ -z "$identity_hash" ]]; then
    echo "专用签名身份创建失败。" >&2
    exit 3
fi

echo "驾驶舱专用签名身份已就绪：$identity_name ($identity_hash)"
echo "$keychain_path"
