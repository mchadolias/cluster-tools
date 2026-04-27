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
# Parse samples block from YAML using Python
# Output format: one line per sample/identifier pair
#   <sample_name>:<identifier1>:<identifier2>:...
# --------------------------------------------------------------------------- #
log "Parsing samples from: $CONFIG"

SAMPLE_DEFS=$(python3 - "$CONFIG" <<'PYEOF'
import sys, json

config_path = sys.argv[1]

# Minimal YAML parser for the samples block (avoids PyYAML dependency).
# Handles the specific structure used in km3tipi pipeline.yaml.
def parse_samples(path):
    samples = {}
    current_sample = None
    with open(path) as f:
        in_samples = False
        for raw in f:
            line = raw.rstrip()
            stripped = line.lstrip()

            if stripped.startswith("samples:"):
                in_samples = True
                continue

            if not in_samples:
                continue

            # Stop if we hit a new top-level key (no leading spaces)
            if line and not line[0].isspace() and not stripped.startswith("samples:"):
                break

            indent = len(line) - len(stripped)

            # Sample name: 2-space indent, ends with ':'
            if indent == 2 and stripped.endswith(":") and not stripped.startswith("identifiers"):
                current_sample = stripped[:-1]
                samples[current_sample] = []

            # identifiers list (inline): identifiers: ["a", "b"]
            if current_sample and stripped.startswith("identifiers:"):
                ids_part = stripped.split("identifiers:", 1)[1].strip()
                # parse as JSON list
                ids_part = ids_part.replace("'", '"')
                try:
                    ids = json.loads(ids_part)
                    samples[current_sample] = ids
                except json.JSONDecodeError:
                    pass

    return samples

samples = parse_samples(config_path)
for name, ids in samples.items():
    print(f"{name}:" + ":".join(ids))
PYEOF
)

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

for filepath in "${FILES[@]}"; do
    basename_file=$(basename "$filepath")
    matched=false
    filesize=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null || echo 0)

    for name in "${SAMPLE_NAMES[@]}"; do
        IFS=' ' read -ra ids <<< "${SAMPLE_IDS[$name]}"
        for id in "${ids[@]}"; do
            if [[ "$basename_file" == *".$id."* ]]; then
                SAMPLE_COUNTS["$name"]=$(( SAMPLE_COUNTS["$name"] + 1 ))
                SAMPLE_SIZES["$name"]=$(( SAMPLE_SIZES["$name"] + filesize ))
                matched=true
                break 2
            fi
        done
    done

    if ! $matched; then
        (( UNCLASSIFIED++ )) || true
        (( UNCLASSIFIED_BYTES += filesize )) || true
    fi
done

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

    local grand_total=0 grand_bytes=0
    for name in "${SAMPLE_NAMES[@]}"; do
        count="${SAMPLE_COUNTS[$name]}"
        bytes="${SAMPLE_SIZES[$name]}"
        ids="${SAMPLE_IDS[$name]}"
        ids_display=$(echo "$ids" | tr ' ' ', ')
        grand_total=$(( grand_total + count ))
        grand_bytes=$(( grand_bytes + bytes ))

        count_padded=$(printf "%*s" "$COUNT_W" "$count")
        size_str=$(human_size "$bytes")
        size_padded=$(printf "%*s" "$SIZE_W" "$size_str")

        if [[ "$count" -gt 0 ]]; then
            avg_bytes=$(( bytes / count ))
            avg_str=$(human_size "$avg_bytes")
            avg_padded=$(printf "%*s" "$AVG_W" "$avg_str")
        else
            avg_str="—"
            avg_padded=$(printf "%*s" $(( AVG_W + 2 )) "$avg_str")
        fi

        if [[ "$count" -eq 0 ]]; then
            count_fmt="${DIM}${count_padded}${RESET}"
            size_fmt="${DIM}${size_padded}${RESET}"
            avg_fmt="${DIM}${avg_padded}${RESET}"
        else
            count_fmt="${GREEN}${count_padded}${RESET}"
            size_fmt="${CYAN}${size_padded}${RESET}"
            avg_fmt="${CYAN}${avg_padded}${RESET}"
        fi

        printf "│ %-*s │ %s │ %s │ %s │ %-*s │\n" \
            "$COL_W" "$name" "$count_fmt" "$size_fmt" "$avg_fmt" "$ID_W" "$ids_display"
    done

    # unclassified row
    printf "${BOLD}├─%s─┼─%s─┼─%s─┼─%s─┼─%s─┤${RESET}\n" "$sep_name" "$sep_count" "$sep_size" "$sep_avg" "$sep_ids"
    unc_padded=$(printf "%*s" "$COUNT_W" "$UNCLASSIFIED")
    unc_size_str=$(human_size "$UNCLASSIFIED_BYTES")
    unc_size_padded=$(printf "%*s" "$SIZE_W" "$unc_size_str")
    if [[ "$UNCLASSIFIED" -gt 0 ]]; then
        unc_avg_bytes=$(( UNCLASSIFIED_BYTES / UNCLASSIFIED ))
        unc_avg_str=$(human_size "$unc_avg_bytes")
        unc_fmt="${YELLOW}${unc_padded}${RESET}"
        unc_size_fmt="${YELLOW}${unc_size_padded}${RESET}"
        unc_avg_fmt="${YELLOW}$(printf "%*s" "$AVG_W" "$unc_avg_str")${RESET}"
    else
        unc_fmt="${DIM}${unc_padded}${RESET}"
        unc_size_fmt="${DIM}${unc_size_padded}${RESET}"
        unc_avg_fmt="${DIM}$(printf "%*s" $(( AVG_W + 2 )) "—")${RESET}"
    fi
    printf "│ %-*s │ %s │ %s │ %s │ %-*s │\n" \
        "$COL_W" "unclassified" "$unc_fmt" "$unc_size_fmt" "$unc_avg_fmt" "$ID_W" "(no matching identifier)"

    printf "${BOLD}├─%s─┼─%s─┼─%s─┼─%s─┼─%s─┤${RESET}\n" "$sep_name" "$sep_count" "$sep_size" "$sep_avg" "$sep_ids"
    grand_total=$(( grand_total + UNCLASSIFIED ))
    grand_bytes=$(( grand_bytes + UNCLASSIFIED_BYTES ))
    total_size_str=$(human_size "$grand_bytes")
    if [[ "$grand_total" -gt 0 ]]; then
        total_avg_str=$(human_size $(( grand_bytes / grand_total )))
    else
        total_avg_str="—"
    fi
    printf "${BOLD}│ %-*s │ %*s │ %*s │ %*s │ %-*s │${RESET}\n" \
        "$COL_W" "TOTAL" "$COUNT_W" "$grand_total" "$SIZE_W" "$total_size_str" "$AVG_W" "$total_avg_str" "$ID_W" ""
    printf "${BOLD}└─%s─┴─%s─┴─%s─┴─%s─┴─%s─┘${RESET}\n" "$sep_name" "$sep_count" "$sep_size" "$sep_avg" "$sep_ids"
}

render_csv() {
    echo "sample,count,size_bytes,size_human,avg_bytes,avg_human,identifiers"
    for name in "${SAMPLE_NAMES[@]}"; do
        ids="${SAMPLE_IDS[$name]}"
        ids_csv=$(echo "$ids" | tr ' ' '|')
        bytes="${SAMPLE_SIZES[$name]}"
        count="${SAMPLE_COUNTS[$name]}"
        if [[ "$count" -gt 0 ]]; then
            avg_bytes=$(( bytes / count ))
            avg_human=$(human_size "$avg_bytes")
        else
            avg_bytes=0; avg_human="—"
        fi
        echo "${name},${count},${bytes},$(human_size "$bytes"),${avg_bytes},${avg_human},${ids_csv}"
    done
    local grand_total=0 grand_bytes=0
    for name in "${SAMPLE_NAMES[@]}"; do
        grand_total=$(( grand_total + SAMPLE_COUNTS[$name] ))
        grand_bytes=$(( grand_bytes + SAMPLE_SIZES[$name] ))
    done
    if [[ "$UNCLASSIFIED" -gt 0 ]]; then
        unc_avg=$(( UNCLASSIFIED_BYTES / UNCLASSIFIED ))
        unc_avg_h=$(human_size "$unc_avg")
    else
        unc_avg=0; unc_avg_h="—"
    fi
    echo "unclassified,${UNCLASSIFIED},${UNCLASSIFIED_BYTES},$(human_size "$UNCLASSIFIED_BYTES"),${unc_avg},${unc_avg_h},"
    grand_total=$(( grand_total + UNCLASSIFIED ))
    grand_bytes=$(( grand_bytes + UNCLASSIFIED_BYTES ))
    if [[ "$grand_total" -gt 0 ]]; then
        total_avg=$(( grand_bytes / grand_total ))
        total_avg_h=$(human_size "$total_avg")
    else
        total_avg=0; total_avg_h="—"
    fi
    echo "TOTAL,${grand_total},${grand_bytes},$(human_size "$grand_bytes"),${total_avg},${total_avg_h},"
}

# --------------------------------------------------------------------------- #
# Print
# --------------------------------------------------------------------------- #
echo ""
echo -e "${BOLD} km3tipi — file count per sample${RESET}"
echo -e "${DIM} config : $CONFIG${RESET}"
echo -e "${DIM} dir    : $DIRECTORY${RESET}"
echo -e "${DIM} pattern: $PATTERN${RESET}"
echo ""

if $CSV_OUT; then
    if [[ -n "$OUTPUT_FILE" ]]; then
        render_csv | tee "$OUTPUT_FILE"
    else
        render_csv
    fi
else
    if [[ -n "$OUTPUT_FILE" ]]; then
        render_table
        render_csv > "$OUTPUT_FILE"
        log "CSV also written to: $OUTPUT_FILE"
    else
        render_table
    fi
fi