#!/usr/bin/env bash
set -e

echo "📦  Installazione afk.sh..."

DEST="$HOME/.local/bin"
mkdir -p "$DEST"

cp afk.sh "$DEST/afk"
chmod +x "$DEST/afk"

# Aggiungi al PATH se non c'è
if [[ ":$PATH:" != *":$DEST:"* ]]; then
  SHELL_RC="$HOME/.bashrc"
  [[ -n "$ZSH_VERSION" ]] && SHELL_RC="$HOME/.zshrc"
  echo '' >> "$SHELL_RC"
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
  echo "  ✓ Aggiunto $DEST al PATH in $SHELL_RC"
  echo "    Esegui: source $SHELL_RC"
fi

echo "  ✓ afk installato in $DEST/afk"
echo "    Esegui: afk --help"