#!/usr/bin/env bash
# =============================================================================
# extract_missing.sh
#
# Read a runlist-filter log (.log or .txt) and split the quoted missing-file
# paths into one plain list per type: DST, BDT, Sparks.
#
# Usage:
#   ./extract_missing.sh <log_file> [output_dir]
#
# Produces (in output_dir, default = current directory):
#   <stem>_DST.txt      one path per line, deduplicated
#   <stem>_BDT.txt
#   <stem>_Sparks.txt
#
# Where <stem> is the input filename without its .log/.txt extension.
#
# The "_dynamic/static.offline (neither found)" shorthand is expanded into
# the two real candidate paths.
# =============================================================================

set -euo pipefail

LOG_FILE="${1:-}"
OUT_DIR="${2:-.}"

if [[ -z "$LOG_FILE" ]]; then
    echo "Usage: $0 <log_file.{log,txt}> [output_dir]" >&2
    exit 1
fi
if [[ ! -r "$LOG_FILE" ]]; then
    echo "ERROR: cannot read $LOG_FILE" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

# Strip .log or .txt extension for the output stem
stem="$(basename "$LOG_FILE")"
stem="${stem%.log}"
stem="${stem%.txt}"

DST_OUT="$OUT_DIR/${stem}_DST.txt"
BDT_OUT="$OUT_DIR/${stem}_BDT.txt"
SPK_OUT="$OUT_DIR/${stem}_Sparks.txt"

# Truncate any previous outputs
: > "$DST_OUT"
: > "$BDT_OUT"
: > "$SPK_OUT"

# Expand the "_dynamic/static.offline (neither found)" shorthand
expand() {
    local p="$1"
    if [[ "$p" == *"(neither found)"* ]]; then
        local needle='_dynamic/static.offline (neither found)'
        printf '%s\n' "${p/$needle/_dynamic.offline}"
        printf '%s\n' "${p/$needle/_static.offline}"
    else
        printf '%s\n' "$p"
    fi
}

# Single awk pass: tag each "- /path" line with the most recent section header
while IFS=$'\t' read -r cat path; do
    while IFS= read -r p; do
        case "$cat" in
            DST)    printf '%s\n' "$p" >> "$DST_OUT" ;;
            BDT)    printf '%s\n' "$p" >> "$BDT_OUT" ;;
            Sparks) printf '%s\n' "$p" >> "$SPK_OUT" ;;
        esac
    done < <(expand "$path")
done < <(
    awk '
        /^[[:space:]]+DST files missing:/   { cat = "DST";    next }
        /^[[:space:]]+BDT scores missing:/  { cat = "BDT";    next }
        /^[[:space:]]+Sparks missing:/      { cat = "Sparks"; next }
        /^[[:space:]]+-[[:space:]]+\//      {
            sub(/^[[:space:]]+-[[:space:]]+/, "")
            if (cat != "") print cat "\t" $0
        }
    ' "$LOG_FILE"
)

# Deduplicate each output (sorted for stable diffs)
for f in "$DST_OUT" "$BDT_OUT" "$SPK_OUT"; do
    sort -u -o "$f" "$f"
done

# Summary
echo "Extracted from: $LOG_FILE"
printf "  %-40s  %s\n" "File" "Paths"
printf "  %-40s  %s\n" "----" "-----"
for f in "$DST_OUT" "$BDT_OUT" "$SPK_OUT"; do
    printf "  %-40s  %d\n" "$(basename "$f")" "$(wc -l < "$f")"
done