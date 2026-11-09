#!/bin/zsh
# sign-app.sh <DotStudio.app> <identity SHA-1> [keychain]
# Re-signs a built DotStudio.app inside-out with the stable release identity (see setup-signing.sh),
# keeping each nested component's own entitlements. Used by .github/workflows/release.yml.
set -euo pipefail

APP="$1"; ID="$2"; KC="${3:-}"
KCARG=(); [[ -n "$KC" ]] && KCARG=(--keychain "$KC")
sign() { codesign --force --timestamp=none "${KCARG[@]}" -s "$ID" "$@"; }

SP="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SP" ]]; then
  for xpc in "$SP"/Versions/B/XPCServices/*.xpc(N); do sign --preserve-metadata=entitlements,flags "$xpc"; done
  [[ -e "$SP/Versions/B/Autoupdate" ]] && sign --preserve-metadata=entitlements,flags "$SP/Versions/B/Autoupdate"
  [[ -d "$SP/Versions/B/Updater.app" ]] && sign --preserve-metadata=entitlements,flags "$SP/Versions/B/Updater.app"
  sign "$SP"
fi
for fw in "$APP"/Contents/Frameworks/*.framework(N); do [[ "$fw" == "$SP" ]] || sign "$fw"; done
SAVER="$APP/Contents/Resources/DotStudio.saver"
[[ -d "$SAVER" ]] && sign --preserve-metadata=entitlements,flags "$SAVER"
sign --preserve-metadata=entitlements,flags "$APP"

codesign --verify --deep --strict "$APP"
DR=$(codesign -d -r- "$APP" 2>&1 | grep designated)
echo "$DR"
[[ "$DR" == *"certificate leaf"* ]] || { echo "error: not signed with the stable identity" >&2; exit 1; }
