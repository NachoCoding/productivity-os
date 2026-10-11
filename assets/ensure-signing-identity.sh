#!/bin/bash
# Creates a stable local code-signing identity once. Signing with it (instead of ad-hoc)
# keeps macOS privacy grants such as Accessibility valid across rebuilds.
set -euo pipefail
name='Productivity OS Local Signing'
if /usr/bin/security find-identity -p codesigning | grep -q "\"$name\""; then exit 0; fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
pass="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
  -passout "pass:$pass" -out "$work/identity.p12"
/usr/bin/security import "$work/identity.p12" -P "$pass" -T /usr/bin/codesign >/dev/null
echo "Created signing identity: $name"
