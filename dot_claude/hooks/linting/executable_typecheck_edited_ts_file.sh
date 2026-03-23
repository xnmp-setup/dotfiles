#!/bin/bash
INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE" ] && exit 0

# Only check pure TS files (svelte files handled by svelte_check_edited_file.sh)
case "$FILE" in
  *.ts) ;;
  *) exit 0 ;;
esac

PROJECT_ROOT=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$PROJECT_ROOT" ] && exit 0
[ ! -f "$PROJECT_ROOT/tsconfig.json" ] && exit 0

BASENAME=$(basename "$FILE")

# Stage 1: run tsc
RAW=$(cd "$PROJECT_ROOT" && npx tsc --noEmit 2>&1)

# Stage 2: find lines mentioning the file
FILE_LINES=$(echo "$RAW" | grep -F "$BASENAME")

# Stage 3: no mentions = no issues
if [ -z "$FILE_LINES" ]; then
  exit 0
fi

# Stage 4: parse — tsc format is "path(line,col): error TSxxxx: message"
PARSED=$(echo "$FILE_LINES" | grep "error TS" | sed "s|.*$BASENAME(|  |; s|): error |: error |")

# Stage 5: fallback if parsing failed
if [ -z "$PARSED" ]; then
  echo "tsc issues in $BASENAME (failed to parse, showing raw):" >&2
  echo "$FILE_LINES" >&2
  exit 2
fi

# Stage 6: print parsed
echo "tsc errors in $BASENAME:" >&2
echo "$PARSED" >&2
exit 2
