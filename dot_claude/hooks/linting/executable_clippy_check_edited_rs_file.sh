#!/bin/bash
# Hook: Run cargo clippy on edited Rust files
# Event: PostToolUse (Edit|Write)

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE" ] && exit 0

case "$FILE" in
  *.rs) ;;
  *) exit 0 ;;
esac

PROJECT_ROOT=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$PROJECT_ROOT" ] && exit 0

# Find the nearest Cargo.toml (could be in a subdirectory like src-tauri/)
CARGO_DIR=$(dirname "$FILE")
while [ "$CARGO_DIR" != "/" ]; do
  [ -f "$CARGO_DIR/Cargo.toml" ] && break
  CARGO_DIR=$(dirname "$CARGO_DIR")
done
[ ! -f "$CARGO_DIR/Cargo.toml" ] && exit 0

BASENAME=$(basename "$FILE")

# Run clippy
RAW=$(cd "$CARGO_DIR" && cargo clippy --message-format short 2>&1)

# Find lines mentioning the file
FILE_LINES=$(echo "$RAW" | grep -F "$BASENAME")
[ -z "$FILE_LINES" ] && exit 0

# Filter to errors and warnings
ISSUES=$(echo "$FILE_LINES" | grep -E '(error|warning)\[')

if [ -z "$ISSUES" ]; then
  exit 0
fi

echo "clippy issues in $BASENAME:" >&2
echo "$ISSUES" >&2

# Only block on errors, not warnings
if echo "$ISSUES" | grep -q 'error\['; then
  exit 2
fi
exit 0
