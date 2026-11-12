#!/bin/sh
# DotStudio Desktop Extension launcher: run the MCP server that ships inside DotStudio.app, so the
# extension never goes stale when DotStudio updates itself.
for app in "$DOTSTUDIO_APP" "/Applications/DotStudio.app" "$HOME/Applications/DotStudio.app"; do
  if [ -n "$app" ] && [ -x "$app/Contents/MacOS/dotstudio-mcp" ]; then
    exec "$app/Contents/MacOS/dotstudio-mcp" "$@"
  fi
done
# Elsewhere (Spotlight knows it by its bundle id).
app=$(mdfind "kMDItemCFBundleIdentifier == 'com.davidlam.DotStudio'" 2>/dev/null | head -n 1)
if [ -n "$app" ] && [ -x "$app/Contents/MacOS/dotstudio-mcp" ]; then
  exec "$app/Contents/MacOS/dotstudio-mcp" "$@"
fi
echo "DotStudio isn't installed (or is older than 1.5). Get it from https://github.com/dw2lam/DotStudio/releases/latest and move it to Applications." >&2
exit 1
