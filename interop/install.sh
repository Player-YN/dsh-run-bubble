#!/bin/zsh
set -eu
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.dsh/interop"
BIN="$HOME/.local/bin"
NODE="$(command -v node || true)"
if [ -z "$NODE" ] && [ -x /opt/homebrew/bin/node ]; then NODE=/opt/homebrew/bin/node; fi
[ -n "$NODE" ] || { echo "node not found" >&2; exit 1; }
mkdir -p "$DEST" "$BIN"
cp "$ROOT/dsh-chat.mjs" "$DEST/dsh-chat.mjs"
cp "$ROOT/SKILL.md" "$DEST/SKILL.md"
chmod 755 "$DEST/dsh-chat.mjs"
cat > "$BIN/dsh-chat" <<EOF
#!/bin/sh
exec "$NODE" "\$HOME/.dsh/interop/dsh-chat.mjs" "\$@"
EOF
chmod 755 "$BIN/dsh-chat"
echo "installed: $BIN/dsh-chat"
echo "skill:     $DEST/SKILL.md"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "note: add $BIN to PATH, or call $BIN/dsh-chat directly" ;;
esac
