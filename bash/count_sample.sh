#!/usr/bin/env bash
# =============================================================================
# count_samples.sh — Count files per sample as defined in pipeline.yaml
#
# Reads the 'samples' block from a km3tipi pipeline.yaml and counts how many
# files in a directory match each sample's identifiers (dot-bounded field match,
# e.g. identifier "pure_noise" matches ".pure_noise." in the filename).
# Unmatched files are reported as 'unclassified'.
#
# Usage:
#   count_samples.sh [OPTIONS] <directory>
#
# Examples:
#   count_samples.sh /data/km3net/dst
#   count_samples.sh -c config/pipeline.yaml -p "*.root" -r /data/km3net/dst
#   count_samples.sh --csv -o counts.csv /data/km3net/dst
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
CONFIG="config/pipeline.yaml"
PATTERN="*"
RECURSIVE=false
CSV_OUT=false
SHOW_RUNS=false
OUTPUT_FILE=""

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
# Usage
# --------------------------------------------------------------------------- #
usage() {
cat <<EOF
${BOLD}count_samples.sh${RESET} — count files per km3tipi sample

${BOLD}USAGE${RESET}
  $(basename "$0") [OPTIONS] <directory>

${BOLD}OPTIONS${RESET}
  -c, --config FILE    Path to pipeline.yaml  (default: config/pipeline.yaml)
  -p, --pattern GLOB   File pattern to match  (default: '*')
  -r, --recursive      Recurse into subdirectories
      --runs           Print a per-run × per-sample detail table after the
                       main one (incomplete runs first).
      --csv            Print output as CSV instead of a table
  -o, --output FILE    Write table/CSV to FILE (in addition to stdout)
  -h, --help           Show this help

${BOLD}EXAMPLES${RESET}
  $(basename "$0") /data/km3net/dst
  $(basename "$0") -c config/pipeline.yaml -p "*.root" -r /data/km3net/dst
  $(basename "$0") --csv -o counts.csv /data/km3net/dst
EOF
}

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)    CONFIG="$2";      shift 2 ;;
        -p|--pattern)   PATTERN="$2";     shift 2 ;;
        -r|--recursive) RECURSIVE=true;   shift   ;;
        --runs)         SHOW_RUNS=true;   shift   ;;
        --csv)          CSV_OUT=true;     shift   ;;
        -o|--output)    OUTPUT_FILE="$2"; shift 2 ;;
        -h|--help)      usage; exit 0             ;;
        -*)             die "Unknown option: $1"  ;;
        *)              POSITIONAL+=("$1"); shift  ;;
    esac
done

[[ ${#POSITIONAL[@]} -eq 1 ]] || { usage; die "Exactly 1 positional argument required: <directory>"; }
DIRECTORY="${POSITIONAL[0]}"

[[ -d "$DIRECTORY" ]] || die "Directory not found: $DIRECTORY"
[[ -f "$CONFIG"    ]] || die "Config file not found: $CONFIG"

# --------------------------------------------------------------------------- #
# Dependency check
# --------------------------------------------------------------------------- #
command -v python3 &>/dev/null || die "python3 is required to parse YAML."

# --------------------------------------------------------------------------- #
# Parse samples block from YAML
# --------------------------------------------------------------------------- #
log "Parsing samples from: $CONFIG"

PIPELINE_CONFIG="$(dirname "${BASH_SOURCE[0]}")/../scripts/pipeline_config.py"
[[ -f "$PIPELINE_CONFIG" ]] || die "pipeline_config.py not found at $PIPELINE_CONFIG"

SAMPLE_DEFS=$(python3 "$PIPELINE_CONFIG" -c "$CONFIG" samples --format kv) \
    || die "Failed to parse $CONFIG (see pipeline_config.py output above)."

[[ -z "$SAMPLE_DEFS" ]] && die "No samples found in $CONFIG. Check the 'samples:' block format."

# --------------------------------------------------------------------------- #
# Collect files from directory
# --------------------------------------------------------------------------- #
log "Scanning directory: $DIRECTORY"

if $RECURSIVE; then
    mapfile -t FILES < <(find "$DIRECTORY" -type f -name "$PATTERN" | sort)
else
    mapfile -t FILES < <(find "$DIRECTORY" -maxdepth 1 -type f -name "$PATTERN" | sort)
fi

TOTAL_FILES=${#FILES[@]}
log "Found ${BOLD}${TOTAL_FILES}${RESET} file(s) matching pattern '${PATTERN}'."

[[ "$TOTAL_FILES" -eq 0 ]] && { warn "No files found. Exiting."; exit 0; }

# --------------------------------------------------------------------------- #
# Count files per sample
# --------------------------------------------------------------------------- #
# Build arrays: sample names, their identifiers, and counts
declare -a SAMPLE_NAMES=()
declare -A SAMPLE_IDS=()    # sample_name -> space-joined identifiers
declare -A SAMPLE_COUNTS=() # sample_name -> count
declare -A SAMPLE_SIZES=()  # sample_name -> total bytes

while IFS= read -r line; do
    IFS=':' read -ra parts <<< "$line"
    name="${parts[0]}"
    ids=("${parts[@]:1}")
    SAMPLE_NAMES+=("$name")
    SAMPLE_IDS["$name"]="${ids[*]}"
    SAMPLE_COUNTS["$name"]=0
    SAMPLE_SIZES["$name"]=0
done <<< "$SAMPLE_DEFS"

UNCLASSIFIED=0
UNCLASSIFIED_BYTES=0

# Run tracking
declare -a ALL_RUN_IDS=()              # ordered list of distinct run IDs
declare -A RUN_SEEN=()                 # run_id -> 1 (de-dup helper)
declare -A RUN_SAMPLE_COUNTS=()        # "<run_id>|<sample>" -> file count
N_FILES_NO_RUN_ID=0                    # files where extraction failed

for filepath in "${FILES[@]}"; do
    basename_file=$(basename "$filepath")
    matched=false
    filesize=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null || echo 0)

    # --- Extract run ID: last 4+ digit numeric token in basename ---
    # Bash regex (POSIX ERE) is used here — mawk's `{4,}` is broken.
    run_id=""
    rest="$basename_file"
    while [[ "$rest" =~ ([0-9]{4,}) ]]; do
        run_id="${BASH_REMATCH[1]}"
        rest="${rest#*"$run_id"}"
    done
    [[ -z "$run_id" ]] && (( N_FILES_NO_RUN_ID++ )) || true

    # --- Match against samples ---
    for name in "${SAMPLE_NAMES[@]}"; do
        IFS=' ' read -ra ids <<< "${SAMPLE_IDS[$name]}"
        for id in "${ids[@]}"; do
            if [[ "$basename_file" == *".$id."* ]]; then
                SAMPLE_COUNTS["$name"]=$(( SAMPLE_COUNTS["$name"] + 1 ))
                SAMPLE_SIZES["$name"]=$(( SAMPLE_SIZES["$name"] + filesize ))
                matched=true
                if [[ -n "$run_id" ]]; then
                    # Register the run only when it has at least one matched file.
                    # Runs that appear only in unclassified files don't count.
                    if [[ -z "${RUN_SEEN[$run_id]:-}" ]]; then
                        RUN_SEEN[$run_id]=1
                        ALL_RUN_IDS+=("$run_id")
                    fi
                    key="${run_id}|${name}"
                    RUN_SAMPLE_COUNTS[$key]=$(( ${RUN_SAMPLE_COUNTS[$key]:-0} + 1 ))
                fi
                break 2
            fi
        done
    done

    if ! $matched; then
        (( UNCLASSIFIED++ )) || true
        (( UNCLASSIFIED_BYTES += filesize )) || true
    fi
done

# --------------------------------------------------------------------------- #
# Run completeness: distinct runs, full runs, per-sample run coverage
# --------------------------------------------------------------------------- #
N_DISTINCT_RUNS=${#ALL_RUN_IDS[@]}
N_FULL_RUNS=0
declare -A SAMPLE_RUN_COVERAGE=()      # sample -> # of runs with ≥1 file
for name in "${SAMPLE_NAMES[@]}"; do
    SAMPLE_RUN_COVERAGE[$name]=0
done

for run_id in "${ALL_RUN_IDS[@]}"; do
    is_full=true
    for name in "${SAMPLE_NAMES[@]}"; do
        c="${RUN_SAMPLE_COUNTS[${run_id}|${name}]:-0}"
        if (( c > 0 )); then
            SAMPLE_RUN_COVERAGE[$name]=$(( SAMPLE_RUN_COVERAGE[$name] + 1 ))
        else
            is_full=false
        fi
    done
    $is_full && (( N_FULL_RUNS++ )) || true
done

# --------------------------------------------------------------------------- #
# Grand totals (computed once, used by both render_table and render_csv)
# --------------------------------------------------------------------------- #
GRAND_TOTAL=0
GRAND_BYTES=0
for name in "${SAMPLE_NAMES[@]}"; do
    GRAND_TOTAL=$(( GRAND_TOTAL + SAMPLE_COUNTS[$name] ))
    GRAND_BYTES=$(( GRAND_BYTES + SAMPLE_SIZES[$name] ))
done
GRAND_TOTAL=$(( GRAND_TOTAL + UNCLASSIFIED ))
GRAND_BYTES=$(( GRAND_BYTES + UNCLASSIFIED_BYTES ))

# Human-readable size formatter (B, KB, MB, GB, TB)
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
# Render output
# --------------------------------------------------------------------------- #

# Find longest sample name for column width
MAX_NAME_LEN=14  # min width to fit "unclassified"
for name in "${SAMPLE_NAMES[@]}"; do
    [[ ${#name} -gt $MAX_NAME_LEN ]] && MAX_NAME_LEN=${#name}
done
COL_W=$(( MAX_NAME_LEN + 2 ))
COUNT_W=10
SIZE_W=10
AVG_W=12
ID_W=40

render_table() {
    local sep_name sep_count sep_size sep_avg sep_ids
    sep_name=$(printf  '%.0s─' $(seq 1 $COL_W))
    sep_count=$(printf '%.0s─' $(seq 1 $COUNT_W))
    sep_size=$(printf  '%.0s─' $(seq 1 $SIZE_W))
    sep_avg=$(printf   '%.0s─' $(seq 1 $AVG_W))
    sep_ids=$(printf   '%.0s─' $(seq 1 $ID_W))

    printf "${BOLD}┌─%s─┬─%s─┬─%s─┬─%s─┬─%s─┐${RESET}\n" "$sep_name" "$sep_count" "$sep_size" "$sep_avg" "$sep_ids"
    printf "${BOLD}│ %-*s │ %*s │ %*s │ %*s │ %-*s │${RESET}\n" \
        "$COL_W" "SAMPLE" "$COUNT_W" "COUNT" "$SIZE_W" "SIZE" "$AVG_W" "AVG/FILE" "$ID_W" "IDENTIFIERS"
    printf "${BOLD}├─%s─┼─%s─┼─%s─┼─%s─┼─%s─┤${RESET}\n" "$sep_name" "$sep_count" "$sep_size" "$sep_avg" "$sep_ids"

    for name in "${SAMPLE_NAMES[@]}"; do
        ids_display=$(echo "${SAMPLE_IDS[$name]}" | tr ' ' ',')
        _render_table_row "$name" "${SAMPLE_COUNTS[$name]}" "${SAMPLE_SIZES[$name]}" \
                          "$ids_display" sample
    done

    printf "${BOLD}├─%s─┼─%s─┼─%s─┼─%s─┼─%s─┤${RESET}\n" "$sep_name" "$sep_count" "$sep_size" "$sep_avg" "$sep_ids"
    _render_table_row "unclassified" "$UNCLASSIFIED" "$UNCLASSIFIED_BYTES" \
                      "(no matching identifier)" unclassified

    printf "${BOLD}├─%s─┼─%s─┼─%s─┼─%s─┼─%s─┤${RESET}\n" "$sep_name" "$sep_count" "$sep_size" "$sep_avg" "$sep_ids"
    _render_table_row "TOTAL" "$GRAND_TOTAL" "$GRAND_BYTES" "" total
    printf "${BOLD}└─%s─┴─%s─┴─%s─┴─%s─┴─%s─┘${RESET}\n" "$sep_name" "$sep_count" "$sep_size" "$sep_avg" "$sep_ids"
}

# Render one row of the sample table.
# Args: name, count, bytes, ids_display, kind ∈ {sample, unclassified, total}
_render_table_row() {
    local name="$1" count="$2" bytes="$3" ids="$4" kind="$5"
    local count_padded size_padded avg_padded
    local size_str avg_str
    local count_fmt size_fmt avg_fmt name_fmt row_close

    count_padded=$(printf "%*s" "$COUNT_W" "$count")
    size_str=$(human_size "$bytes")
    size_padded=$(printf "%*s" "$SIZE_W" "$size_str")

    if (( count > 0 )); then
        avg_str=$(human_size $(( bytes / count )))
        avg_padded=$(printf "%*s" "$AVG_W" "$avg_str")
    else
        # The em-dash is a multi-byte char, so widen the field by 2 to compensate.
        avg_padded=$(printf "%*s" $(( AVG_W + 2 )) "—")
    fi

    case "$kind" in
        sample)
            if (( count > 0 )); then
                count_fmt="${GREEN}${count_padded}${RESET}"
                size_fmt="${CYAN}${size_padded}${RESET}"
                avg_fmt="${CYAN}${avg_padded}${RESET}"
            else
                count_fmt="${DIM}${count_padded}${RESET}"
                size_fmt="${DIM}${size_padded}${RESET}"
                avg_fmt="${DIM}${avg_padded}${RESET}"
            fi
            name_fmt=$(printf "%-*s" "$COL_W" "$name")
            ;;
        unclassified)
            if (( count > 0 )); then
                count_fmt="${YELLOW}${count_padded}${RESET}"
                size_fmt="${YELLOW}${size_padded}${RESET}"
                avg_fmt="${YELLOW}${avg_padded}${RESET}"
            else
                count_fmt="${DIM}${count_padded}${RESET}"
                size_fmt="${DIM}${size_padded}${RESET}"
                avg_fmt="${DIM}${avg_padded}${RESET}"
            fi
            name_fmt=$(printf "%-*s" "$COL_W" "$name")
            ;;
        total)
            count_fmt="${BOLD}${count_padded}${RESET}"
            size_fmt="${BOLD}${size_padded}${RESET}"
            avg_fmt="${BOLD}${avg_padded}${RESET}"
            # Pad first, then wrap — ANSI codes don't count toward width.
            name_fmt="${BOLD}$(printf "%-*s" "$COL_W" "$name")${RESET}"
            ;;
    esac

    printf "│ %s │ %s │ %s │ %s │ %-*s │\n" \
        "$name_fmt" "$count_fmt" "$size_fmt" "$avg_fmt" "$ID_W" "$ids"
}

render_csv() {
    echo "sample,count,size_bytes,size_human,avg_bytes,avg_human,identifiers"
    for name in "${SAMPLE_NAMES[@]}"; do
        ids_csv=$(echo "${SAMPLE_IDS[$name]}" | tr ' ' '|')
        _render_csv_row "$name" "${SAMPLE_COUNTS[$name]}" "${SAMPLE_SIZES[$name]}" "$ids_csv"
    done
    _render_csv_row "unclassified" "$UNCLASSIFIED" "$UNCLASSIFIED_BYTES" ""
    _render_csv_row "TOTAL"        "$GRAND_TOTAL"  "$GRAND_BYTES"        ""
}

# Emit one CSV row.  Args: name, count, bytes, ids_csv
_render_csv_row() {
    local name="$1" count="$2" bytes="$3" ids="$4"
    local avg_bytes avg_human
    if (( count > 0 )); then
        avg_bytes=$(( bytes / count ))
        avg_human=$(human_size "$avg_bytes")
    else
        avg_bytes=0
        avg_human="—"
    fi
    echo "${name},${count},${bytes},$(human_size "$bytes"),${avg_bytes},${avg_human},${ids}"
}

# --------------------------------------------------------------------------- #
# Run rendering helpers
# --------------------------------------------------------------------------- #

# Print run IDs to stdout, ordered with the most-incomplete first.
# Tie-break by run_id ascending so the output is deterministic.
sort_runs_by_completeness() {
    for run_id in "${ALL_RUN_IDS[@]}"; do
        n_present=0
        for name in "${SAMPLE_NAMES[@]}"; do
            c="${RUN_SAMPLE_COUNTS[${run_id}|${name}]:-0}"
            (( c > 0 )) && n_present=$(( n_present + 1 ))
        done
        printf "%04d %s\n" "$n_present" "$run_id"
    done | sort | awk '{print $2}'
}

# Returns 0 (true) if every configured sample has ≥1 file for this run.
run_is_full() {
    local run_id="$1" name c
    for name in "${SAMPLE_NAMES[@]}"; do
        c="${RUN_SAMPLE_COUNTS[${run_id}|${name}]:-0}"
        (( c == 0 )) && return 1
    done
    return 0
}

# Compact summary block, always shown for the table view.
render_run_summary() {
    local pct="—"
    if (( N_DISTINCT_RUNS > 0 )); then
        pct=$(awk -v n="$N_FULL_RUNS" -v d="$N_DISTINCT_RUNS" \
              'BEGIN { printf "%.1f", n*100/d }')"%"
    fi

    echo
    echo -e "${BOLD} run summary${RESET}"
    printf "   distinct runs              : %s\n" "$N_DISTINCT_RUNS"
    printf "   full runs (all %d sample%s)  : %s  (%s)\n" \
        "${#SAMPLE_NAMES[@]}" \
        "$( (( ${#SAMPLE_NAMES[@]} == 1 )) && echo "" || echo "s")" \
        "$N_FULL_RUNS" "$pct"

    if (( N_FILES_NO_RUN_ID > 0 )); then
        printf "   files with no run ID       : %s  ${DIM}(skipped from run analysis)${RESET}\n" \
            "$N_FILES_NO_RUN_ID"
    fi

    echo
    printf "   ${DIM}per-sample run coverage:${RESET}\n"
    for name in "${SAMPLE_NAMES[@]}"; do
        cov="${SAMPLE_RUN_COVERAGE[$name]}"
        miss=$(( N_DISTINCT_RUNS - cov ))
        if (( miss == 0 && N_DISTINCT_RUNS > 0 )); then
            marker="${GREEN}✓${RESET}"
        elif (( cov == 0 )); then
            marker="${RED}✗${RESET}"
        else
            marker="${YELLOW}~${RESET}"
        fi
        printf "     %s %-*s : %4d covered, %4d missing\n" \
            "$marker" "$MAX_NAME_LEN" "$name" "$cov" "$miss"
    done
}

# Per-run × per-sample matrix.  Incomplete runs first.
render_run_detail() {
    if (( N_DISTINCT_RUNS == 0 )); then
        echo
        warn "No run IDs detected — skipping run detail table."
        return
    fi

    # Decide column width per sample column: max(name, 5)
    local -A SCOL_W
    for name in "${SAMPLE_NAMES[@]}"; do
        local w=${#name}
        (( w < 5 )) && w=5
        SCOL_W[$name]=$w
    done

    echo
    echo -e "${BOLD} run detail (incomplete runs first)${RESET}"

    # Header
    printf "  %-10s" "RUN ID"
    for name in "${SAMPLE_NAMES[@]}"; do
        printf "  %*s" "${SCOL_W[$name]}" "$name"
    done
    printf "  %s\n" "FULL"

    local sorted_runs run_id name c
    sorted_runs=$(sort_runs_by_completeness)

    while IFS= read -r run_id; do
        [[ -z "$run_id" ]] && continue
        printf "  %-10s" "$run_id"
        for name in "${SAMPLE_NAMES[@]}"; do
            c="${RUN_SAMPLE_COUNTS[${run_id}|${name}]:-0}"
            if (( c > 0 )); then
                printf "  ${GREEN}%*d${RESET}" "${SCOL_W[$name]}" "$c"
            else
                printf "  ${DIM}%*s${RESET}" "${SCOL_W[$name]}" "-"
            fi
        done
        if run_is_full "$run_id"; then
            printf "  ${GREEN}✓${RESET}\n"
        else
            printf "  ${RED}✗${RESET}\n"
        fi
    done <<< "$sorted_runs"
}

# CSV variant of the per-run matrix
render_runs_csv() {
    local hdr="run_id" name run_id row c sorted_runs
    for name in "${SAMPLE_NAMES[@]}"; do
        hdr="${hdr},${name}"
    done
    echo "${hdr},full"

    sorted_runs=$(sort_runs_by_completeness)

    while IFS= read -r run_id; do
        [[ -z "$run_id" ]] && continue
        row="$run_id"
        for name in "${SAMPLE_NAMES[@]}"; do
            c="${RUN_SAMPLE_COUNTS[${run_id}|${name}]:-0}"
            row="${row},${c}"
        done
        if run_is_full "$run_id"; then row="${row},1"; else row="${row},0"; fi
        echo "$row"
    done <<< "$sorted_runs"
}

# --------------------------------------------------------------------------- #
# Print
# --------------------------------------------------------------------------- #

# Emit the full CSV report (samples + optional runs section) on stdout.
emit_csv_report() {
    render_csv
    if $SHOW_RUNS; then
        echo
        echo "# runs"
        render_runs_csv
    fi
}

# Emit the human report on stdout: table + always-on run summary + optional detail.
emit_table_report() {
    render_table
    render_run_summary
    $SHOW_RUNS && render_run_detail
}

echo ""
echo -e "${BOLD} km3tipi — file count per sample${RESET}"
echo -e "${DIM} config : $CONFIG${RESET}"
echo -e "${DIM} dir    : $DIRECTORY${RESET}"
echo -e "${DIM} pattern: $PATTERN${RESET}"
echo ""

if $CSV_OUT; then
    # Single output stream; tee to file if requested, otherwise to /dev/null.
    emit_csv_report | tee "${OUTPUT_FILE:-/dev/null}"
else
    emit_table_report
    if [[ -n "$OUTPUT_FILE" ]]; then
        emit_csv_report > "$OUTPUT_FILE"
        log "CSV also written to: $OUTPUT_FILE"
    fi
fi