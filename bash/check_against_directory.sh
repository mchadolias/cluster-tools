#!/usr/bin/env bash
# =============================================================================
# check_against_dir.sh
#
# Given a plain list of file paths (one per line, e.g. produced by
# extract_missing.sh) and one or more target directories, report which
# basenames are present in any of those directories and which are still
# missing.
#
# A basename counts as "appeared" as soon as it is found in any of the
# given directories. The first match (in the order directories are given on
# the command line) is recorded.
#
# Usage:
#   ./check_against_dir.sh <list_file> <dir1> [<dir2> ...]
#
# Produces (next to the list file):
#   <stem>.appeared.txt   <mtime> | <directory> | <basename>
#   <stem>.missing.txt    <basename>
# =============================================================================

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <list_file> <dir1> [<dir2> ...]" >&2
    exit 1
fi

LIST_FILE="$1"
shift
DIRS=("$@")

if [[ ! -r "$LIST_FILE" ]]; then
    echo "ERROR: cannot read $LIST_FILE" >&2
    exit 1
fi

# Validate every directory up front
for d in "${DIRS[@]}"; do
    if [[ ! -d "$d" ]]; then
        echo "ERROR: not a directory: $d" >&2
        exit 1
    fi
done

# Output filenames are derived from the list file's stem
stem="${LIST_FILE%.txt}"
APPEARED="${stem}.appeared.txt"
MISSING="${stem}.missing.txt"

now() { date '+%Y-%m-%d %H:%M:%S'; }

# Render the list of directories for the file headers
dirs_csv="$(printf '%s, ' "${DIRS[@]}")"; dirs_csv="${dirs_csv%, }"

{
    echo "# Files present in any of the target directories"
    echo "# Source list : $LIST_FILE"
    echo "# Directories : $dirs_csv"
    echo "# Generated   : $(now)"
    echo "# Format      : <mtime> | <directory> | <basename>"
    echo
} > "$APPEARED"

{
    echo "# Files still missing from all target directories"
    echo "# Source list : $LIST_FILE"
    echo "# Directories : $dirs_csv"
    echo "# Generated   : $(now)"
    echo
} > "$MISSING"

# Colours (only on TTY)
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; GREEN=$'\033[32m'; RED=$'\033[31m'
    DIM=$'\033[2m'; RST=$'\033[0m'
else
    BOLD=''; GREEN=''; RED=''; DIM=''; RST=''
fi

# Per-directory hit counters (associative array keyed by directory)
declare -A hits_per_dir=()
for d in "${DIRS[@]}"; do
    hits_per_dir["$d"]=0
done

appeared=0
missing=0
total=0

while IFS= read -r path; do
    # Skip blank and comment lines
    [[ -z "$path" || "${path:0:1}" == "#" ]] && continue
    total=$((total + 1))

    name="$(basename "$path")"

    # Search each directory in order; first hit wins
    found_dir=""
    for d in "${DIRS[@]}"; do
        if [[ -e "$d/$name" ]]; then
            found_dir="$d"
            break
        fi
    done

    if [[ -n "$found_dir" ]]; then
        mtime="$(date -r "$found_dir/$name" '+%Y-%m-%d %H:%M:%S')"
        printf '%s | %s | %s\n' "$mtime" "$found_dir" "$name" >> "$APPEARED"
        appeared=$((appeared + 1))
        hits_per_dir["$found_dir"]=$(( ${hits_per_dir["$found_dir"]} + 1 ))
    else
        printf '%s\n' "$name" >> "$MISSING"
        missing=$((missing + 1))
    fi
done < "$LIST_FILE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "${BOLD}=== Check ${LIST_FILE} against ${#DIRS[@]} director$( ((${#DIRS[@]}==1)) && echo y || echo ies) ===${RST}"
echo "  Total entries  : $total"
echo "  ${GREEN}Now present    : $appeared${RST}  ->  $APPEARED"
echo "  ${RED}Still missing  : $missing${RST}  ->  $MISSING"

# Per-directory breakdown (only worth showing if more than one dir given)
if (( ${#DIRS[@]} > 1 )); then
    echo
    echo "  ${BOLD}Hits per directory:${RST}"
    for d in "${DIRS[@]}"; do
        printf "    %s%6d%s  %s\n" "$GREEN" "${hits_per_dir["$d"]}" "$RST" "$d"
    done
fi

if [[ $appeared -gt 0 ]]; then
    echo
    echo "${GREEN}${BOLD}Files that have appeared:${RST}"
    tail -n +7 "$APPEARED" \
        | awk -F' \\| ' -v dim="$DIM" -v rst="$RST" \
              '{ printf "  %s%s%s  [%s]  %s\n", dim, $1, rst, $2, $3 }'
fi