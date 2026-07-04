#!/usr/bin/env bash
#
# make-dev-cert.sh — create a stable, self-signed *code-signing* identity in your
# login keychain so macOS remembers TCC grants (Calendar, etc.) across rebuilds.
#
# Why: an ad-hoc-signed app ("-") has no stable identity, so macOS forgets the
# Calendar permission every time you rebuild and re-asks. Signing with a fixed
# self-signed identity gives TCC something durable to remember. Free, no Apple
# Developer account needed. Idempotent: safe to run repeatedly.
#
# Usage:  scripts/make-dev-cert.sh ["Identity Name"]   (default: "Jotty Dev")
set -euo pipefail

IDENTITY="${1:-Jotty Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  echo "✓ Code-signing identity '$IDENTITY' already exists — nothing to do."
  exit 0
fi

echo "Creating self-signed code-signing identity '$IDENTITY'…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions   = ext
prompt            = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints   = critical, CA:false
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
EOF

# Self-signed cert + key with the codeSigning extended-key-usage (required for codesign).
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1

# Bundle into a PKCS#12 (empty passphrase) and import into the login keychain,
# pre-authorizing /usr/bin/codesign to use the private key.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -name "$IDENTITY" -passout pass: >/dev/null 2>&1

security import "$TMP/id.p12" -k "$KEYCHAIN" -P "" \
  -T /usr/bin/codesign -T /usr/bin/productsign >/dev/null

# Best-effort: let codesign use the key without a GUI prompt each time. Needs the
# login-keychain password; if it can't, you'll just click "Always Allow" once the
# first time you sign. Never fatal.
if [ -n "${LOGIN_KEYCHAIN_PASSWORD:-}" ]; then
  security set-key-partition-list -S apple-tool:,apple: -s \
    -k "$LOGIN_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true
fi

echo "✓ Created '$IDENTITY'."
echo "  (First time you sign, macOS may ask to use the key — click 'Always Allow'.)"
