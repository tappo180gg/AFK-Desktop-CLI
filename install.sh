#!/usr/bin/env bash
set -e

echo "📦  Installing afk.sh..."

DEST="$HOME/.local/bin"
mkdir -p "$DEST"

cp afk.sh "$DEST/afk"
chmod +x "$DEST/afk"

# Add to PATH if not already there
if [[ ":$PATH:" != *":$DEST:"* ]]; then
  SHELL_RC="$HOME/.bashrc"
  [[ -n "$ZSH_VERSION" ]] && SHELL_RC="$HOME/.zshrc"
  echo '' >> "$SHELL_RC"
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
  echo "  ✓ Added $DEST to PATH in $SHELL_RC"
  echo "    Run: source $SHELL_RC"
fi

echo "  ✓ afk installed in $DEST/afk"
echo "    Run: afk --help"