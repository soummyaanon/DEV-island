#!/usr/bin/env bash
# One-time: a local, self-signed code-signing identity for development builds.
#
# Ad-hoc signatures change with every build, and macOS ties privacy grants
# (Accessibility, Bluetooth, Calendar, Automation, Paste) to the signature, so
# every rebuild asked again. Signed with one stable identity, a dev build keeps
# its grants across rebuilds. bundle.sh uses it automatically once it exists.
#
# It lives in its own keychain (no password, never your login keychain) and
# only ever signs this app on this Mac. Remove it with:
#   security delete-keychain ~/Library/Keychains/agent-island-dev.keychain-db
set -euo pipefail

name="Agent Island Dev"
keychain="$HOME/Library/Keychains/agent-island-dev.keychain-db"

if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
  echo "\"$name\" already exists in $keychain"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
  -passout pass:island -out "$work/identity.p12" 2>/dev/null

security create-keychain -p "" "$keychain"
security set-keychain-settings "$keychain"
security unlock-keychain -p "" "$keychain"
security import "$work/identity.p12" -k "$keychain" -P island -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$keychain" >/dev/null
# Keep the existing search list, and add this keychain to it.
existing=$(security list-keychains -d user | tr -d '"' | xargs)
security list-keychains -d user -s $existing "$keychain"

echo "Created \"$name\" in $keychain"
