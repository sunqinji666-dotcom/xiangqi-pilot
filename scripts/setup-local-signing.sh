#!/bin/zsh
set -euo pipefail

identity_name="${XIANGQI_LOCAL_SIGNING_NAME:-Xiangqi Pilot Local Signing}"
keychain_path="${XIANGQI_SIGNING_KEYCHAIN:-$(security default-keychain -d user | tr -d ' "\n')}"

if [[ -z "$keychain_path" ]]; then
    echo "无法确定当前用户钥匙串。" >&2
    exit 1
fi

find_identity_hash() {
    security find-identity -v -p codesigning "$keychain_path" 2>/dev/null \
        | awk -v label="$identity_name" 'index($0, "\"" label "\"") { print $2; exit }'
}

existing_hash="$(find_identity_hash)"
if [[ -n "$existing_hash" ]]; then
    echo "本地签名身份已就绪：$identity_name ($existing_hash)"
    exit 0
fi

if security find-certificate -c "$identity_name" "$keychain_path" >/dev/null 2>&1; then
    echo "发现同名证书，但它不是可用的代码签名身份。请先在“钥匙串访问”中检查：$identity_name" >&2
    exit 2
fi

umask 077
temporary_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/xiangqi-pilot-signing.XXXXXX")"
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

# Trust is restricted to the Code Signing policy. This does not make the
# certificate a trusted website, email, or installer authority.
security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$keychain_path" \
    "$certificate"

identity_hash="$(find_identity_hash)"
if [[ -z "$identity_hash" ]]; then
    echo "证书已导入，但代码签名身份仍不可用。" >&2
    exit 3
fi

echo "已创建稳定的本地代码签名身份：$identity_name ($identity_hash)"
echo "私钥不可导出，并且只授权给 /usr/bin/codesign 使用。"
