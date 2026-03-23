#!/bin/bash
INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE" ] && exit 0

case "$FILE" in
  *.svelte) ;;
  *) exit 0 ;;
esac

PROJECT_ROOT=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$PROJECT_ROOT" ] && exit 0
# Skip non-Svelte projects
ls "$PROJECT_ROOT"/svelte.config.* >/dev/null 2>&1 || exit 0

BASENAME=$(basename "$FILE")

# Stage 1: get raw output
RAW=$(cd "$PROJECT_ROOT" && bunx svelte-check --tsconfig ./tsconfig.json 2>&1)

# Stage 2: find lines mentioning the file
FILE_LINES=$(echo "$RAW" | grep -F "$BASENAME")

# Stage 3: if file not mentioned at all, no issues
if [ -z "$FILE_LINES" ]; then
  exit 0
fi

# Stage 4: parse — grab filename lines + the line after each (Error:/Warn:)
# Pair each path:line:col with its Error/Warn message
PARSED=$(echo "$RAW" | awk -v basename="$BASENAME" '
  $0 ~ basename {
    match($0, /:[0-9]+:[0-9]+$/)
    if (RSTART > 0) {
      loc = substr($0, RSTART+1)
    } else {
      loc = "?:?"
    }
    getline next_line
    if (next_line ~ /^(Error|Warn):/) {
      printf "  %s %s\n", loc, next_line
    }
  }
')

# Stage 5: if parsing found nothing, print raw as fallback
if [ -z "$PARSED" ]; then
  echo "svelte-check issues in $BASENAME (failed to parse, showing raw):" >&2
  echo "$FILE_LINES" >&2
  exit 2
fi

# Stage 6: print parsed results, only block on errors (not warnings)
echo "svelte-check issues in $BASENAME:" >&2
echo "$PARSED" >&2
if echo "$PARSED" | grep -q "Error:"; then
  exit 2
fi
exit 0
