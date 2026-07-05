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

# NOTE: no `-v` here. A self-signed cert is untrusted, so `find-identity -v`
# (valid AND trusted only) would NOT list it and we'd re-import on every run.
# codesign can still SIGN with an untrusted identity (trust only matters for
# others VERIFYING), so the plain policy listing is the right idempotency check.
if security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
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

# Bundle into a PKCS#12 and import into the login keychain, pre-authorizing
# /usr/bin/codesign to use the private key.
#
# OpenSSL 3.x defaults the PKCS#12 to a SHA-256 MAC + AES-256 that macOS's
# `security import` cannot read — it fails as "MAC verification failed (wrong
# password?)". Use `-legacy` when the openssl on PATH supports it (OpenSSL 3.x)
# so the p12 uses the SHA1-MAC/3DES form macOS accepts, and use a real passphrase
# (empty-password p12 import is also flaky on macOS).
P12_PASS="jotty-local"
LEGACY=""
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then LEGACY="-legacy"; fi
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -name "$IDENTITY" -passout "pass:$P12_PASS" >/dev/null 2>&1

security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/productsign

# Best-effort: let codesign use the key without a GUI prompt each time. Needs the
# login-keychain password; if it can't, you'll just click "Always Allow" once the
# first time you sign. Never fatal.
if [ -n "${LOGIN_KEYCHAIN_PASSWORD:-}" ]; then
  security set-key-partition-list -S apple-tool:,apple: -s \
    -k "$LOGIN_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true
fi

echo "✓ Created '$IDENTITY'."
echo "  (First time you sign, macOS may ask to use the key — click 'Always Allow'.)"
