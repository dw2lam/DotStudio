#!/bin/zsh
# setup-signing.sh — one-time: create DotStudio's stable code-signing identity and hand it to CI.
#
# Why: ad-hoc signatures change with every build, so macOS treats every update as a new app
# and forgets privacy grants (e.g. "DotStudio wants to control Spotify/Music"). Signing every
# release with the SAME self-signed certificate gives a stable designated requirement
#   identifier "com.davidlam.DotStudio" and certificate leaf = H"<sha1>"
# so grants survive Sparkle updates. Sparkle accepts the switch because the EdDSA key is unchanged.
# The certificate does not need to be trusted for codesign (verified 2026-11-09).
#
# What it does:
#   1. creates a 10-year RSA-2048 code-signing certificate + key (CN "DotStudio Release Signing")
#   2. exports it as a password-protected .p12 into ~/.dotstudio-signing/ (chmod 700) — BACK THIS UP:
#      losing it means every user's grants reset once on the next update
#   3. stores it as GitHub Actions secrets SIGNING_P12_BASE64 + SIGNING_P12_PASSWORD (needs gh auth)
#
# Re-running is safe: it reuses an existing ~/.dotstudio-signing/DotStudio-signing.p12.
set -euo pipefail

REPO="${DOTSTUDIO_REPO:-dw2lam/DotStudio}"
DIR="$HOME/.dotstudio-signing"
P12="$DIR/DotStudio-signing.p12"
PASSFILE="$DIR/p12-password.txt"
CN="DotStudio Release Signing"

mkdir -p "$DIR"; chmod 700 "$DIR"

if [[ ! -f "$P12" ]]; then
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$CN" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
  PASS=$(openssl rand -base64 24)
  # -legacy: Apple's `security import` can't read the default (AES/PBKDF2) p12 MAC.
  openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$CN" -out "$P12" -passout "pass:$PASS" 2>/dev/null
  print -r -- "$PASS" > "$PASSFILE"; chmod 600 "$P12" "$PASSFILE"
  echo "Created $P12"
else
  echo "Reusing $P12"
fi

SHA1=$(openssl pkcs12 -legacy -in "$P12" -nokeys -passin "file:$PASSFILE" 2>/dev/null \
       | openssl x509 -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
echo "Certificate SHA-1: $SHA1"

base64 -i "$P12" | gh secret set SIGNING_P12_BASE64 -R "$REPO"
gh secret set SIGNING_P12_PASSWORD -R "$REPO" < "$PASSFILE"
echo "Stored SIGNING_P12_BASE64 + SIGNING_P12_PASSWORD on $REPO."
echo "Back up $DIR somewhere safe (e.g. your password manager)."
