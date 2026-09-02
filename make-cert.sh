#!/bin/bash
# One-time: create a local code-signing identity so BigSwitch keeps its permissions across rebuilds.
# The key lives only in your login keychain, signs only what you tell it to, and involves no Apple account.
set -e
NAME="BigSwitch Local Signing"
KEYCHAIN=~/Library/Keychains/login.keychain-db

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "✓ identity already exists"; exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# a certificate whose only power is code signing
openssl req -x509 -newkey rsa:2048 -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -days 7300 -nodes \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# macOS keychain only understands the older PKCS#12 encryption, not OpenSSL 3's default
openssl pkcs12 -export -out "$tmp/bs.p12" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -passout pass:bigswitch -name "$NAME" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

security import "$tmp/bs.p12" -k "$KEYCHAIN" -P bigswitch -T /usr/bin/codesign

# trust it for code signing — THIS is the step that shows one password dialog
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem"

security find-identity -v -p codesigning | grep "$NAME" && echo "✓ identity ready"
echo "note: the first build signed with it may show a Keychain prompt — click 'Always Allow'"
