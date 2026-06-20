#!/usr/bin/env bash
# =============================================================================
# diff_dirs.sh — Compare files in two directories for km3tipi pipelines
#
# Checks for:
#   - Files present in DIR_A but missing in DIR_B        (only in A)
#   - Files present in DIR_B but missing in DIR_A        (only in B)
#   - Files present in both but with different sizes     (size mismatch)
#   - Files present in both, same size, different hash   (content mismatch)
#   - Files present in both, same size, same hash        (identical)
#
# Checksums are only computed for files that pass the size-match check,
# so the cost is proportional to the number of candidates, not all files.
#
# Output:
#   --list FILE      writes one annotated report covering every category.
#   --split-dir DIR  writes one clean filename-per-line list per category
#                    (only_in_<A>.txt, only_in_<B>.txt, size_mismatch.txt,
#                    content_mismatch.txt, identical.txt, all_diffs.txt).
#                    These are directly consumable by 'transfer_data.sh --list'.
#
# Usage:
#   diff_dirs.sh [OPTIONS] <dir_a> <dir_b>
#
# Examples:
#   diff_dirs.sh -p "*.root" /data/km3net/raw /scratch/sample
#   diff_dirs.sh -p "*.root" --hash sha256 --list diff.txt \
#       /data/km3net/raw /scratch/sample
#   diff_dirs.sh --no-checksum --csv -o report.csv \
#       /data/km3net/raw /scratch/sample
#   diff_dirs.sh -p "*.root" --split-dir diff_lists \
#       /data/km3net/raw /scratch/sample
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Colours
# --------------------------------------------------------------------------- #
RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'

log()  { echo -e "${CYAN}[INFO]${RESET}  $*" >&2; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
PATTERN="*"
LIST_FILE=""
SPLIT_DIR=""
CSV_OUT=false
OUTPUT_FILE=""
LABEL_A="DIR_A"
LABEL_B="DIR_B"
HASH_ALG="md5"
DO_CHECKSUM=true

# --------------------------------------------------------------------------- #
# Usage
# --------------------------------------------------------------------------- #
usage() {
cat <<EOF
${BOLD}diff_dirs.sh${RESET} — compare files between two directories

${BOLD}USAGE${RESET}
  $(basename "$0") [OPTIONS] <dir_a> <dir_b>

${BOLD}OPTIONS${RESET}
  -p, --pattern GLOB     File pattern to match (default: '*')
  -A, --label-a NAME     Label for dir_a in output (default: DIR_A)
  -B, --label-b NAME     Label for dir_b in output (default: DIR_B)
      --hash ALG         Checksum algorithm: md5 or sha256 (default: md5)
      --no-checksum      Skip checksum step (size comparison only)
      --list FILE        Write the full diff file list to FILE
  -S, --split-dir DIR    Also write one clean filename-per-line list per category
                         into DIR (only_in_<A>.txt, only_in_<B>.txt,
                         size_mismatch.txt, content_mismatch.txt, identical.txt,
                         plus all_diffs.txt). These are directly consumable by
                         'transfer_data.sh --list'.
      --csv              Print summary as CSV instead of table
  -o, --output FILE      Write CSV report to FILE
  -h, --help             Show this help

${BOLD}EXAMPLES${RESET}
  $(basename "$0") -p "*.root" /data/km3net/raw /scratch/sample
  $(basename "$0") -p "*.root" --hash sha256 -A source -B dest \\
      --list diff.txt /data/km3net/raw /scratch/sample
  $(basename "$0") --no-checksum --csv -o report.csv \\
      /data/km3net/raw /scratch/sample
  # Per-category lists, then re-transfer everything missing/different:
  $(basename "$0") -p "*.root" -A source -B dest \\
      --split-dir diff_lists /data/km3net/raw /scratch/sample
  transfer_data.sh --list diff_lists/only_in_source.txt \\
      /data/km3net/raw /scratch/sample
EOF
}

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--pattern)     PATTERN="$2";      shift 2 ;;
        -A|--label-a)     LABEL_A="$2";      shift 2 ;;
        -B|--label-b)     LABEL_B="$2";      shift 2 ;;
        --hash)           HASH_ALG="$2";     shift 2 ;;
        --no-checksum)    DO_CHECKSUM=false;  shift   ;;
        --list)           LIST_FILE="$2";    shift 2 ;;
        -S|--split-dir)   SPLIT_DIR="$2";    shift 2 ;;
        --csv)            CSV_OUT=true;      shift   ;;
        -o|--output)      OUTPUT_FILE="$2";  shift 2 ;;
        -h|--help)        usage; exit 0              ;;
        -*)               die "Unknown option: $1"   ;;
        *)                POSITIONAL+=("$1"); shift   ;;
    esac
done

[[ ${#POSITIONAL[@]} -eq 2 ]] || { usage; die "Exactly 2 positional arguments required: <dir_a> <dir_b>"; }
DIR_A="${POSITIONAL[0]}"
DIR_B="${POSITIONAL[1]}"

[[ -d "$DIR_A" ]] || die "Directory not found: $DIR_A"
[[ -d "$DIR_B" ]] || die "Directory not found: $DIR_B"
[[ "$HASH_ALG" == "md5" || "$HASH_ALG" == "sha256" ]] \
    || die "Unsupported hash algorithm: $HASH_ALG (use md5 or sha256)"

# --------------------------------------------------------------------------- #
# Detect checksum tool (Linux: md5sum/sha256sum  macOS: md5/shasum)
# --------------------------------------------------------------------------- #
detect_hash_cmd() {
    local alg="$1"
    if [[ "$alg" == "md5" ]]; then
        if   command -v md5sum &>/dev/null; then echo "md5sum"
        elif command -v md5    &>/dev/null; then echo "md5 -q"
        else die "No md5 tool found (tried md5sum, md5)"; fi
    else
        if   command -v sha256sum &>/dev/null; then echo "sha256sum"
        elif command -v shasum    &>/dev/null; then echo "shasum -a 256"
        else die "No sha256 tool found (tried sha256sum, shasum)"; fi
    fi
}

compute_hash() {
    # Returns just the hex digest, strips trailing filename
    $HASH_CMD "$1" 2>/dev/null | awk '{print $1}'
}

# --------------------------------------------------------------------------- #
# Human-readable size
# --------------------------------------------------------------------------- #
human_size() {
    local bytes=$1
    if   (( bytes >= 1099511627776 )); then printf "%.2f TB" "$(echo "scale=2; $bytes/1099511627776" | bc)"
    elif (( bytes >=    1073741824 )); then printf "%.2f GB" "$(echo "scale=2; $bytes/1073741824"    | bc)"
    elif (( bytes >=       1048576 )); then printf "%.2f MB" "$(echo "scale=2; $bytes/1048576"       | bc)"
    elif (( bytes >=          1024 )); then printf "%.2f KB" "$(echo "scale=2; $bytes/1024"          | bc)"
    else printf "%d B" "$bytes"
    fi
}

# --------------------------------------------------------------------------- #
# Collect files: filename -> size, filename -> full path
# --------------------------------------------------------------------------- #
log "Scanning ${BOLD}${LABEL_A}${RESET}: $DIR_A"
log "Scanning ${BOLD}${LABEL_B}${RESET}: $DIR_B"

declare -A FILES_A=()  # filename -> size
declare -A FILES_B=()
declare -A PATH_A=()   # filename -> full path
declare -A PATH_B=()

while IFS= read -r filepath; do
    fname=$(basename "$filepath")
    fsize=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null || echo 0)
    FILES_A["$fname"]="$fsize"
    PATH_A["$fname"]="$filepath"
done < <(find "$DIR_A" -maxdepth 1 -type f -name "$PATTERN" | sort)

while IFS= read -r filepath; do
    fname=$(basename "$filepath")
    fsize=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null || echo 0)
    FILES_B["$fname"]="$fsize"
    PATH_B["$fname"]="$filepath"
done < <(find "$DIR_B" -maxdepth 1 -type f -name "$PATTERN" | sort)

TOTAL_A=${#FILES_A[@]}
TOTAL_B=${#FILES_B[@]}
log "Found ${BOLD}${TOTAL_A}${RESET} file(s) in ${LABEL_A}, ${BOLD}${TOTAL_B}${RESET} file(s) in ${LABEL_B}."

# --------------------------------------------------------------------------- #
# Phase 1: presence + size
# --------------------------------------------------------------------------- #
declare -a ONLY_A=()
declare -a ONLY_B=()
declare -a SIZE_MISMATCH=()
declare -a SIZE_MATCH=()    # candidates for checksum

for fname in "${!FILES_A[@]}"; do
    if [[ -z "${FILES_B[$fname]+x}" ]]; then
        ONLY_A+=("$fname")
    elif [[ "${FILES_A[$fname]}" != "${FILES_B[$fname]}" ]]; then
        SIZE_MISMATCH+=("$fname")
    else
        SIZE_MATCH+=("$fname")
    fi
done

for fname in "${!FILES_B[@]}"; do
    [[ -z "${FILES_A[$fname]+x}" ]] && ONLY_B+=("$fname")
done

IFS=$'\n' ONLY_A=($(sort        <<<"${ONLY_A[*]+${ONLY_A[*]}}")); unset IFS
IFS=$'\n' ONLY_B=($(sort        <<<"${ONLY_B[*]+${ONLY_B[*]}}")); unset IFS
IFS=$'\n' SIZE_MISMATCH=($(sort  <<<"${SIZE_MISMATCH[*]+${SIZE_MISMATCH[*]}}")); unset IFS
IFS=$'\n' SIZE_MATCH=($(sort     <<<"${SIZE_MATCH[*]+${SIZE_MATCH[*]}}")); unset IFS

# --------------------------------------------------------------------------- #
# Phase 2: checksum (only on size-matched candidates)
# --------------------------------------------------------------------------- #
declare -a CONTENT_MISMATCH=()
declare -a IDENTICAL=()
declare -A HASH_A=()
declare -A HASH_B=()

if $DO_CHECKSUM && [[ ${#SIZE_MATCH[@]} -gt 0 ]]; then
    HASH_CMD=$(detect_hash_cmd "$HASH_ALG")
    log "Computing ${BOLD}${HASH_ALG}${RESET} checksums for ${BOLD}${#SIZE_MATCH[@]}${RESET} size-matched file(s)…"
    n=0
    total_cands=${#SIZE_MATCH[@]}
    for fname in "${SIZE_MATCH[@]}"; do
        (( n++ )) || true
        printf "\r${CYAN}[INFO]${RESET}  Hashing %d/%d: %s   " "$n" "$total_cands" "$fname" >&2
        ha=$(compute_hash "${PATH_A[$fname]}")
        hb=$(compute_hash "${PATH_B[$fname]}")
        HASH_A["$fname"]="$ha"
        HASH_B["$fname"]="$hb"
        if [[ "$ha" == "$hb" ]]; then
            IDENTICAL+=("$fname")
        else
            CONTENT_MISMATCH+=("$fname")
        fi
    done
    printf "\n" >&2
elif ! $DO_CHECKSUM; then
    IDENTICAL=("${SIZE_MATCH[@]+"${SIZE_MATCH[@]}"}")
    log "Checksum skipped (--no-checksum). Size-matched files assumed identical."
else
    IDENTICAL=()
fi

IFS=$'\n' CONTENT_MISMATCH=($(sort <<<"${CONTENT_MISMATCH[*]+${CONTENT_MISMATCH[*]}}")); unset IFS
IFS=$'\n' IDENTICAL=($(sort         <<<"${IDENTICAL[*]+${IDENTICAL[*]}}")); unset IFS

N_ONLY_A=${#ONLY_A[@]}
N_ONLY_B=${#ONLY_B[@]}
N_SIZE_MISMATCH=${#SIZE_MISMATCH[@]}
N_CONTENT_MISMATCH=${#CONTENT_MISMATCH[@]}
N_IDENTICAL=${#IDENTICAL[@]}
N_TOTAL_DIFF=$(( N_ONLY_A + N_ONLY_B + N_SIZE_MISMATCH + N_CONTENT_MISMATCH ))

# --------------------------------------------------------------------------- #
# Render helpers
# --------------------------------------------------------------------------- #
COL_W=22
COUNT_W=8

_row() {
    local label="$1" count="$2" color="$3"
    local padded
    padded=$(printf "%*s" "$COUNT_W" "$count")
    if [[ "$count" -eq 0 ]]; then
        printf "│ %-*s │ %s │\n" "$COL_W" "$label" "${DIM}${padded}${RESET}"
    else
        printf "│ %-*s │ %s │\n" "$COL_W" "$label" "${color}${padded}${RESET}"
    fi
}

render_table() {
    local sep_cat sep_count
    sep_cat=$(printf   '%.0s─' $(seq 1 $COL_W))
    sep_count=$(printf '%.0s─' $(seq 1 $COUNT_W))

    printf "${BOLD}┌─%s─┬─%s─┐${RESET}\n" "$sep_cat" "$sep_count"
    printf "${BOLD}│ %-*s │ %*s │${RESET}\n" "$COL_W" "CATEGORY" "$COUNT_W" "COUNT"
    printf "${BOLD}├─%s─┼─%s─┤${RESET}\n"   "$sep_cat" "$sep_count"

    _row "only in ${LABEL_A}"    "$N_ONLY_A"            "$YELLOW"
    _row "only in ${LABEL_B}"    "$N_ONLY_B"            "$YELLOW"
    _row "size mismatch"         "$N_SIZE_MISMATCH"     "$RED"
    $DO_CHECKSUM && \
        _row "content mismatch"  "$N_CONTENT_MISMATCH"  "$RED"
    _row "identical"             "$N_IDENTICAL"         "$GREEN"

    printf "${BOLD}├─%s─┼─%s─┤${RESET}\n" "$sep_cat" "$sep_count"
    local padded
    padded=$(printf "%*s" "$COUNT_W" "$N_TOTAL_DIFF")
    if [[ "$N_TOTAL_DIFF" -gt 0 ]]; then
        printf "│ %-*s │ %s │\n" "$COL_W" "total diffs" "${RED}${padded}${RESET}"
    else
        printf "│ %-*s │ %s │\n" "$COL_W" "total diffs" "${GREEN}${padded}${RESET}"
    fi
    printf "${BOLD}└─%s─┴─%s─┘${RESET}\n" "$sep_cat" "$sep_count"
}

render_csv() {
    echo "category,count"
    echo "only_in_${LABEL_A},${N_ONLY_A}"
    echo "only_in_${LABEL_B},${N_ONLY_B}"
    echo "size_mismatch,${N_SIZE_MISMATCH}"
    $DO_CHECKSUM && echo "content_mismatch,${N_CONTENT_MISMATCH}"
    echo "identical,${N_IDENTICAL}"
    echo "total_diffs,${N_TOTAL_DIFF}"
}

# --------------------------------------------------------------------------- #
# File list
# --------------------------------------------------------------------------- #
render_list() {
    local out="${1:-/dev/stdout}"
    {
    echo "# diff_dirs.sh report"
    echo "# Generated  : $(date -u +%FT%TZ)"
    echo "# ${LABEL_A}         : $DIR_A  (${TOTAL_A} files)"
    echo "# ${LABEL_B}         : $DIR_B  (${TOTAL_B} files)"
    echo "# Pattern    : $PATTERN"
    $DO_CHECKSUM \
        && echo "# Checksum   : ${HASH_ALG}" \
        || echo "# Checksum   : disabled"
    echo ""

    echo "## Only in ${LABEL_A} (${N_ONLY_A} files)"
    printf "# %-16s  %-12s  %s\n" "STATUS" "SIZE" "FILENAME"
    for fname in "${ONLY_A[@]+"${ONLY_A[@]}"}"; do
        printf "ONLY_A          %-12s  %s\n" "$(human_size "${FILES_A[$fname]}")" "$fname"
    done
    [[ "$N_ONLY_A" -eq 0 ]] && echo "# (none)"
    echo ""

    echo "## Only in ${LABEL_B} (${N_ONLY_B} files)"
    printf "# %-16s  %-12s  %s\n" "STATUS" "SIZE" "FILENAME"
    for fname in "${ONLY_B[@]+"${ONLY_B[@]}"}"; do
        printf "ONLY_B          %-12s  %s\n" "$(human_size "${FILES_B[$fname]}")" "$fname"
    done
    [[ "$N_ONLY_B" -eq 0 ]] && echo "# (none)"
    echo ""

    echo "## Size mismatch (${N_SIZE_MISMATCH} files)"
    printf "# %-16s  %-12s  %-12s  %-14s  %s\n" "STATUS" "SIZE_${LABEL_A}" "SIZE_${LABEL_B}" "DELTA" "FILENAME"
    for fname in "${SIZE_MISMATCH[@]+"${SIZE_MISMATCH[@]}"}"; do
        size_a="${FILES_A[$fname]}"
        size_b="${FILES_B[$fname]}"
        delta=$(( size_b - size_a ))
        sign="+"; [[ "$delta" -lt 0 ]] && sign=""
        printf "SIZE_MISMATCH   %-12s  %-12s  %s%-14s  %s\n" \
            "$(human_size "$size_a")" "$(human_size "$size_b")" \
            "$sign" "$(human_size "${delta#-}")" "$fname"
    done
    [[ "$N_SIZE_MISMATCH" -eq 0 ]] && echo "# (none)"
    echo ""

    if $DO_CHECKSUM; then
        echo "## Content mismatch — same size, different ${HASH_ALG} (${N_CONTENT_MISMATCH} files)"
        printf "# %-18s  %-12s  %-36s  %-36s  %s\n" \
            "STATUS" "SIZE" "HASH_${LABEL_A}" "HASH_${LABEL_B}" "FILENAME"
        for fname in "${CONTENT_MISMATCH[@]+"${CONTENT_MISMATCH[@]}"}"; do
            printf "CONTENT_MISMATCH  %-12s  %-36s  %-36s  %s\n" \
                "$(human_size "${FILES_A[$fname]}")" \
                "${HASH_A[$fname]}" "${HASH_B[$fname]}" "$fname"
        done
        [[ "$N_CONTENT_MISMATCH" -eq 0 ]] && echo "# (none)"
        echo ""
    fi

    echo "## Identical (${N_IDENTICAL} files)"
    printf "# %-16s  %-12s  %s\n" "STATUS" "SIZE" "FILENAME"
    for fname in "${IDENTICAL[@]+"${IDENTICAL[@]}"}"; do
        hash_str=""
        $DO_CHECKSUM && hash_str="  ${HASH_A[$fname]}"
        printf "OK              %-12s%s  %s\n" \
            "$(human_size "${FILES_A[$fname]}")" "$hash_str" "$fname"
    done
    [[ "$N_IDENTICAL" -eq 0 ]] && echo "# (none)"
    } > "$out"
    return 0
}

# --------------------------------------------------------------------------- #
# Per-category clean lists (one filename per line, no decoration)
# Each file is directly consumable by `transfer_data.sh --list`.
# --------------------------------------------------------------------------- #
# Make a filesystem-safe slug from a label (for the only_in_<label> filenames).
slug() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/_/g'
}

# Write an array (passed as args) to a file, one item per line. Empty array
# produces a genuinely empty file rather than a stray blank line.
_write_list() {
    local out="$1"; shift
    if (( $# == 0 )); then
        : > "$out"
    else
        printf '%s\n' "$@" > "$out"
    fi
}

write_split_lists() {
    local dir="$1"
    mkdir -p "$dir" || die "Cannot create split-list directory: $dir"

    local sa sb
    sa=$(slug "$LABEL_A")
    sb=$(slug "$LABEL_B")
    # Guard against both labels slugging to the same name.
    [[ "$sa" == "$sb" ]] && { sa="a_${sa}"; sb="b_${sb}"; }

    _write_list "$dir/only_in_${sa}.txt"   "${ONLY_A[@]+"${ONLY_A[@]}"}"
    _write_list "$dir/only_in_${sb}.txt"   "${ONLY_B[@]+"${ONLY_B[@]}"}"
    _write_list "$dir/size_mismatch.txt"   "${SIZE_MISMATCH[@]+"${SIZE_MISMATCH[@]}"}"
    if $DO_CHECKSUM; then
        _write_list "$dir/content_mismatch.txt" "${CONTENT_MISMATCH[@]+"${CONTENT_MISMATCH[@]}"}"
    fi
    _write_list "$dir/identical.txt"       "${IDENTICAL[@]+"${IDENTICAL[@]}"}"

    # Combined list of everything that differs (sorted, de-duplicated).
    local all_diffs
    all_diffs=$(
        printf '%s\n' \
            "${ONLY_A[@]+"${ONLY_A[@]}"}" \
            "${ONLY_B[@]+"${ONLY_B[@]}"}" \
            "${SIZE_MISMATCH[@]+"${SIZE_MISMATCH[@]}"}" \
            "${CONTENT_MISMATCH[@]+"${CONTENT_MISMATCH[@]}"}" \
            | grep -v '^$' | sort -u || true
    )
    if [[ -n "$all_diffs" ]]; then
        printf '%s\n' "$all_diffs" > "$dir/all_diffs.txt"
    else
        : > "$dir/all_diffs.txt"
    fi

    log "Split lists written to ${BOLD}${dir}/${RESET}:"
    log "  only_in_${sa}.txt     (${N_ONLY_A})"
    log "  only_in_${sb}.txt     (${N_ONLY_B})"
    log "  size_mismatch.txt      (${N_SIZE_MISMATCH})"
    $DO_CHECKSUM && \
    log "  content_mismatch.txt   (${N_CONTENT_MISMATCH})"
    log "  identical.txt          (${N_IDENTICAL})"
    log "  all_diffs.txt          (${N_TOTAL_DIFF})"
    return 0
}

# --------------------------------------------------------------------------- #
# Print
# --------------------------------------------------------------------------- #
echo ""
echo -e "${BOLD} km3tipi — directory diff${RESET}"
echo -e "${DIM} ${LABEL_A}       : $DIR_A  (${TOTAL_A} files)${RESET}"
echo -e "${DIM} ${LABEL_B}       : $DIR_B  (${TOTAL_B} files)${RESET}"
echo -e "${DIM} pattern   : $PATTERN${RESET}"
$DO_CHECKSUM \
    && echo -e "${DIM} checksum  : ${HASH_ALG}${RESET}" \
    || echo -e "${DIM} checksum  : disabled${RESET}"
echo ""

if $CSV_OUT; then
    if [[ -n "$OUTPUT_FILE" ]]; then render_csv | tee "$OUTPUT_FILE"
    else render_csv; fi
else
    render_table
    if [[ -n "$OUTPUT_FILE" ]]; then
        render_csv > "$OUTPUT_FILE"
        log "CSV written to: $OUTPUT_FILE"
    fi
fi

echo ""
if [[ -n "$LIST_FILE" ]]; then
    render_list "$LIST_FILE"
    log "Diff file list written to: $LIST_FILE"
else
    render_list /dev/stdout
fi

if [[ -n "$SPLIT_DIR" ]]; then
    write_split_lists "$SPLIT_DIR"
fi

# Exit non-zero if diffs found (useful for CI / Snakemake guards)
[[ "$N_TOTAL_DIFF" -eq 0 ]] && exit 0 || exit 1