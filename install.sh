#!/usr/bin/env bash
set -e

echo "📦  Installing afk.sh..."

DEST="$HOME/.local/bin"
mkdir -p "$DEST"

REPO_RAW="https://raw.githubusercontent.com/tappo180gg/AFK-Desktop-CLI/refs/heads/main/afk.sh"

# If afk.sh isn't next to this script (e.g. running via
# `curl -fsSL .../install.sh | bash` without cloning the repo first),
# download it straight from GitHub instead of failing.
if [[ -f "afk.sh" ]]; then
  cp afk.sh "$DEST/afk"
else
  echo "  afk.sh not found locally — downloading from GitHub..."
  tmp_download=$(mktemp)
  # Cache-busting query param avoids stale responses from GitHub's raw
  # content CDN, which can serve an old copy for a few minutes after a push.
  dl_url="${REPO_RAW}?_=$(date +%s)"
  if command -v curl &>/dev/null; then
    curl -fsSL "$dl_url" -o "$tmp_download"
  elif command -v wget &>/dev/null; then
    wget -qO "$tmp_download" "$dl_url"
  else
    echo "  ✗ curl or wget required to download afk.sh"
    exit 1
  fi
  if [[ ! -s "$tmp_download" ]] || ! bash -n "$tmp_download" 2>/dev/null; then
    echo "  ✗ Download failed or file is invalid"
    rm -f "$tmp_download"
    exit 1
  fi
  cp "$tmp_download" "$DEST/afk"
  rm -f "$tmp_download"
fi

chmod +x "$DEST/afk"

# Add to PATH if not already there
if [[ ":$PATH:" != *":$DEST:"* ]]; then
  SHELL_RC="$HOME/.bashrc"
  [[ -n "$ZSH_VERSION" ]] && SHELL_RC="$HOME/.zshrc"

  # Some distros (e.g. Arch-based) ship a commented-out PATH line in the
  # default shell rc file. If we find one that already references
  # .local/bin, just uncomment it instead of appending a duplicate export.
  if [[ -f "$SHELL_RC" ]] && grep -qE '^[[:space:]]*#.*\.local/bin' "$SHELL_RC"; then
    # Uncomment the first matching commented line (strip leading '#' and following spaces)
    sed -i '0,/^[[:space:]]*#.*\.local\/bin/{s/^[[:space:]]*#[[:space:]]*//}' "$SHELL_RC"
    echo "  ✓ Found a commented-out PATH line in $SHELL_RC referencing .local/bin — uncommented it"
    echo "    Run: source $SHELL_RC"
  else
    echo '' >> "$SHELL_RC"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
    echo "  ✓ Added $DEST to PATH in $SHELL_RC"
    echo "    Run: source $SHELL_RC"
  fi
else
  # PATH already active in this session, but double-check it's actually
  # persisted in the rc file for future sessions (covers edge cases where
  # $PATH was set some other way, e.g. exported manually or via a parent process).
  SHELL_RC="$HOME/.bashrc"
  [[ -n "$ZSH_VERSION" ]] && SHELL_RC="$HOME/.zshrc"
  if [[ -f "$SHELL_RC" ]] && grep -qE '^[[:space:]]*#.*\.local/bin' "$SHELL_RC" && ! grep -qE '^[[:space:]]*export PATH=.*\.local/bin' "$SHELL_RC"; then
    echo "  ⚠ Note: $SHELL_RC has a commented-out .local/bin PATH line."
    echo "    It's not currently needed (PATH is already set for this session),"
    echo "    but new terminal sessions may not pick it up unless you uncomment it."
  fi
fi

echo "  ✓ afk installed in $DEST/afk"
echo "    Run: afk --help"
