#!/bin/zsh
# docs/ai/mcpb/build.sh [outDir] — pack DotStudio.mcpb, the Claude Desktop extension (a launcher that
# runs the dotstudio-mcp inside DotStudio.app). Validates and packs with the official CLI
# (@anthropic-ai/mcpb) when npx is available, else zips the folder (an .mcpb is a zip).
set -e
HERE="${0:A:h}"
OUT="${1:-$HERE/../../../build}"
mkdir -p "$OUT"
OUT="${OUT:A}"
chmod +x "$HERE/server/launch.sh"
STAGE="$(mktemp -d)"
cp "$HERE/manifest.json" "$HERE/icon.png" "$STAGE/"
cp -R "$HERE/server" "$STAGE/"
if command -v npx >/dev/null; then
  npx -y @anthropic-ai/mcpb@2.1.2 validate "$STAGE/manifest.json"
  npx -y @anthropic-ai/mcpb@2.1.2 pack "$STAGE" "$OUT/DotStudio.mcpb"
else
  rm -f "$OUT/DotStudio.mcpb"
  (cd "$STAGE" && zip -qr "$OUT/DotStudio.mcpb" manifest.json icon.png server)
fi
rm -rf "$STAGE"
echo "built $OUT/DotStudio.mcpb"
