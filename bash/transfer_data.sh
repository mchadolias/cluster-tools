#!/usr/bin/env bash
# =============================================================================
# sample_transfer.sh — Random file sampler & transfer for km3tipi pipelines
#
# Transfers a random sample of files from a source directory to a destination.
# Supports local paths, remote SSH hosts, and XRootD (dcache) endpoints.
#
# Usage:
#   sample_transfer.sh [OPTIONS] <source> <destination>
#
# Source/Destination formats:
#   /local/path                         — local filesystem
#   user@host:/remote/path              — SSH/rsync remote
#   root://xrootd.example.org//path     — XRootD / dcache
#
# Examples:
#   # 20 random files from dcache to local scratch
#   sample_transfer.sh -n 20 -p "*.root" \
#       root://xrootd.km3net.de//km3net/data/raw \
#       /scratch/michalis/sample
#
#   # 10% of files from cluster home to another cluster
#   sample_transfer.sh -f 0.10 \
#       user@lyon:/data/km3net/dst \
#       user@cnaf:/scratch/michalis/dst
#
#   # Dry-run: see what would be transferred
#   sample_transfer.sh -n 50 --dry-run \
#       /data/km3net/raw \
#       /tmp/sample
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
N_FILES=""          # absolute number of files to sample
FRACTION=""         # fraction of files to sample (0 < f <= 1)
N_RUNS=""           # number of runs to sample (transfers all files for those runs)
RUN_IDS=""          # path to a file with run IDs, or a 'START-END' range
LIST_FILE=""        # path to a file with explicit filenames/events to transfer
PATTERN="*"         # glob/filter pattern for file selection
SEED=""             # optional random seed for reproducibility
DRY_RUN=false
VERBOSE=0            # verbosity level: 0=progress bar, 1=per-file, 2=full detail
RECURSIVE=false
RSYNC_OPTS="-az --progress"
XRDCP_OPTS="--parallel 4"
LOG_FILE=""

# --------------------------------------------------------------------------- #
# Colours
# --------------------------------------------------------------------------- #
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
die()  { err "$*"; exit 1; }

# Seeded random sampling. Reads lines from stdin, prints up to N of them.
# Deterministic for a given seed (uses bash $RANDOM, not awk srand which mawk
# does not honour reproducibly across invocations). When seed is empty, falls
# back to `shuf` for non-deterministic sampling.
seeded_sample() {
    local seed="$1" n="$2"
    if [[ -z "$seed" ]]; then
        shuf -n "$n"
        return
    fi
    local -a lines=()
    local l
    while IFS= read -r l; do
        [[ -n "$l" ]] && lines+=("$l")
    done
    local total=${#lines[@]}
    (( n >= total )) && { printf '%s\n' "${lines[@]}"; return; }
    RANDOM="$seed"
    local i j tmp
    # Partial Fisher-Yates: only shuffle the first n positions.
    for ((i = 0; i < n; i++)); do
        j=$(( RANDOM % (total - i) + i ))
        tmp="${lines[i]}"
        lines[i]="${lines[j]}"
        lines[j]="$tmp"
    done
    printf '%s\n' "${lines[@]:0:$n}"
}

# Format a duration in seconds as MM:SS (or H:MM:SS past an hour).
fmt_hms() {
    local s=$1 h m
    (( s < 0 )) && s=0
    h=$(( s / 3600 )); m=$(( (s % 3600) / 60 )); s=$(( s % 60 ))
    if (( h > 0 )); then printf '%d:%02d:%02d' "$h" "$m" "$s"
    else printf '%02d:%02d' "$m" "$s"; fi
}

# Draw a tqdm-style progress bar to stderr (in place, via carriage return).
# args: current total start_epoch
draw_progress() {
    local cur=$1 total=$2 start=$3
    (( total <= 0 )) && total=1
    (( cur > total )) && cur=$total

    local width=30
    local pct=$(( cur * 100 / total ))
    # Work in eighths of a cell so the leading edge can be a partial block.
    local eighths=$(( cur * width * 8 / total ))
    local full=$(( eighths / 8 ))
    local rem=$(( eighths % 8 ))
    local parts=(' ' '▏' '▎' '▍' '▌' '▋' '▊' '▉')

    local bar="" i
    for ((i = 0; i < full; i++)); do bar+="█"; done
    if (( full < width )); then
        if (( rem > 0 )); then bar+="${parts[rem]}"; i=$(( full + 1 ))
        else i=$full; fi
        for (( ; i < width; i++ )); do bar+=" "; done
    fi

    local now elapsed eta_str rate_str
    now=$(date +%s)
    elapsed=$(( now - start ))
    if (( elapsed > 0 && cur > 0 )); then
        local rate_x10=$(( cur * 10 / elapsed ))
        rate_str=$(printf '%d.%d' $(( rate_x10 / 10 )) $(( rate_x10 % 10 )))
        eta_str=$(fmt_hms "$(( (total - cur) * elapsed / cur ))")
    else
        rate_str="0.0"; eta_str="??:??"
    fi

    # Local ESC sequences (the colour vars use echo -e style, not printf-safe).
    local c=$'\033[0;36m' rst=$'\033[0m' clr=$'\033[K'
    printf '\r%s|%s|%s %3d%% %d/%d [%s<%s, %s file/s]%s' \
        "$c" "$bar" "$rst" "$pct" "$cur" "$total" \
        "$(fmt_hms "$elapsed")" "$eta_str" "$rate_str" "$clr" >&2
}

# --------------------------------------------------------------------------- #
# Usage
# --------------------------------------------------------------------------- #
usage() {
cat <<EOF
${BOLD}sample_transfer.sh${RESET} — random file sampler & transfer for km3tipi

${BOLD}USAGE${RESET}
  $(basename "$0") [OPTIONS] <source> <destination>

${BOLD}OPTIONS${RESET}
  -n, --count N        Transfer exactly N files (mutually exclusive with the others)
  -f, --fraction F     Transfer a fraction F of files, e.g. 0.10 for 10%
      --run N          Pick N distinct runs at random from the source and transfer
                       ALL files belonging to those runs. Run IDs are extracted from
                       filenames as the last 4+ digit numeric token of the basename.
      --run-ids ARG    Transfer all files whose names contain a run ID. ARG is either:
                          • a path to a text file with one ID per line ('#' comments OK), or
                          • a numeric range 'START-END' (inclusive on both ends),
                            e.g. '12340-12350'.
  -L, --list FILE      Transfer exactly the files listed in FILE — one filename per
                       line ('#' comments and blank lines ignored, whitespace trimmed).
                       Each entry is matched against the source listing by basename
                       (a full path is also accepted and matched exactly). Useful for
                       transferring a hand-picked set of events. Seed is ignored.
                       The five selection modes (-n, -f, --run, --run-ids, --list) are
                       mutually exclusive.
  -p, --pattern GLOB   File pattern to match, default: '*'
  -s, --seed INT       Random seed for reproducibility (ignored with --run-ids)
  -r, --recursive      Recurse into subdirectories (local/SSH sources)
      --dry-run        Print actions without executing transfers
  -v, --verbose        Increase verbosity (repeatable). Default (no -v) shows a
                       progress bar; -v logs each file's name as it transfers;
                       -vv additionally shows the full source→dest URI and the
                       underlying transfer command.
  -l, --log FILE       Append transfer log to FILE
  -h, --help           Show this help

${BOLD}SOURCE / DESTINATION FORMATS${RESET}
  /local/path                     Local filesystem
  user@host:/remote/path          SSH / rsync remote
  root://host//xrd/path           XRootD / dcache

${BOLD}EXAMPLES${RESET}
  # 20 random .root files from dcache to local
  $(basename "$0") -n 20 -p "*.root" \\
      root://xrootd.km3net.de//km3net/data/raw /scratch/sample

  # 10% of DST files between two SSH clusters
  $(basename "$0") -f 0.10 -p "*.dst.gz" \\
      lyon:/data/km3net/dst cnaf:/scratch/michalis/dst
      
  # Transfer all files for 5 randomly selected runs
  $(basename "$0") --run 5 -s 42 -p "*.root" \\
      /data/km3net/raw /scratch/sample

  # Transfer files matching run IDs from a list
  $(basename "$0") --run-ids runs.txt \\
      root://xrootd.km3net.de//km3net/data/raw /scratch/sample

  # Transfer files for every run ID in a range (inclusive)
  $(basename "$0") --run-ids 12340-12350 -p "*.root" \\
      /data/km3net/raw /scratch/sample

  # Transfer exactly the files named in list.txt
  $(basename "$0") --list list.txt \\
      root://xrootd.km3net.de//km3net/data/raw /scratch/sample

  # Dry-run to verify selection
  $(basename "$0") -n 50 --dry-run /data/km3net/raw /tmp/sample
EOF
}

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--count)     N_FILES="$2";   shift 2 ;;
        -f|--fraction)  FRACTION="$2";  shift 2 ;;
        --run|--n-runs) N_RUNS="$2";    shift 2 ;;
        --run-ids)      RUN_IDS="$2";   shift 2 ;;
        -L|--list)      LIST_FILE="$2"; shift 2 ;;
        -p|--pattern)   PATTERN="$2";   shift 2 ;;
        -s|--seed)      SEED="$2";      shift 2 ;;
        -r|--recursive) RECURSIVE=true; shift   ;;
        --dry-run)      DRY_RUN=true;   shift   ;;
        -v|--verbose)   VERBOSE=$((VERBOSE + 1)); shift ;;
        -vv)            VERBOSE=$((VERBOSE + 2)); shift ;;
        -vvv)           VERBOSE=$((VERBOSE + 3)); shift ;;
        -l|--log)       LOG_FILE="$2";  shift 2 ;;
        -h|--help)      usage; exit 0           ;;
        -*)             die "Unknown option: $1" ;;
        *)              POSITIONAL+=("$1"); shift ;;
    esac
done

[[ ${#POSITIONAL[@]} -eq 2 ]] || { usage; die "Exactly 2 positional args required: <source> <destination>"; }
SOURCE="${POSITIONAL[0]}"
DEST="${POSITIONAL[1]}"

# Selection-mode validation: exactly one of -n / -f / --run / --run-ids / --list
n_modes=0
[[ -n "$N_FILES"  ]] && n_modes=$((n_modes + 1))
[[ -n "$FRACTION" ]] && n_modes=$((n_modes + 1))
[[ -n "$N_RUNS"   ]] && n_modes=$((n_modes + 1))
[[ -n "$RUN_IDS"  ]] && n_modes=$((n_modes + 1))
[[ -n "$LIST_FILE" ]] && n_modes=$((n_modes + 1))

(( n_modes == 0 )) && die "Specify selection with -n <count>, -f <fraction>, --run <N>, --run-ids <arg>, or --list <file>."
(( n_modes >  1 )) && die "Use only one of -n / -f / --run / --run-ids / --list."

if [[ -n "$N_RUNS" ]]; then
    [[ "$N_RUNS" =~ ^[0-9]+$ && "$N_RUNS" -gt 0 ]] \
        || die "--run: expected a positive integer, got '$N_RUNS'."
fi

if [[ -n "$LIST_FILE" ]]; then
    [[ -f "$LIST_FILE" ]] || die "--list: file '$LIST_FILE' does not exist."
fi

if [[ -n "$RUN_IDS" ]]; then
    # Accept either a START-END range or a path to an existing file.
    if [[ "$RUN_IDS" =~ ^[0-9]+-[0-9]+$ ]] || [[ -f "$RUN_IDS" ]]; then
        :
    else
        die "--run-ids: '$RUN_IDS' is neither a START-END range nor an existing file."
    fi
fi

# --------------------------------------------------------------------------- #
# Detect source type
# --------------------------------------------------------------------------- #
detect_type() {
    local path="$1"
    if [[ "$path" == root://* ]]; then
        echo "xrootd"
    elif [[ "$path" == *@*:* || "$path" == *:/* ]]; then
        echo "ssh"
    else
        echo "local"
    fi
}

SRC_TYPE=$(detect_type "$SOURCE")
DST_TYPE=$(detect_type "$DEST")

log "Source type : ${BOLD}${SRC_TYPE}${RESET}  →  ${SOURCE}"
log "Dest type   : ${BOLD}${DST_TYPE}${RESET}  →  ${DEST}"

# --------------------------------------------------------------------------- #
# Load run IDs (if given) — applied as a post-listing filter, not a glob
# --------------------------------------------------------------------------- #
IDS=()
RUN_IDS_SOURCE=""        # "range" or "file" — for log messages
if [[ -n "$RUN_IDS" ]]; then
    if [[ "$RUN_IDS" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        start="${BASH_REMATCH[1]}"
        end="${BASH_REMATCH[2]}"
        [[ "$start" -le "$end" ]] || die "Invalid range: start ($start) > end ($end)"
        for ((id = start; id <= end; id++)); do
            IDS+=("$id")
        done
        RUN_IDS_SOURCE="range"
        log "Expanded range ${BOLD}${start}-${end}${RESET} → ${#IDS[@]} run ID(s)"
    else
        # File: one ID per line, '#' comments + blank lines skipped, whitespace trimmed
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -n "$line" ]] && IDS+=("$line")
        done < "$RUN_IDS"
        [[ ${#IDS[@]} -eq 0 ]] && die "No run IDs found in $RUN_IDS"
        RUN_IDS_SOURCE="file"
        log "Loaded ${BOLD}${#IDS[@]}${RESET} run ID(s) from $RUN_IDS"
    fi
fi

# --------------------------------------------------------------------------- #
# Load explicit filename list (if given) — matched by basename after listing
# --------------------------------------------------------------------------- #
WANTED_NAMES=()
if [[ -n "$LIST_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                              # strip '#' comments
        line="${line#"${line%%[![:space:]]*}"}"         # ltrim
        line="${line%"${line##*[![:space:]]}"}"         # rtrim
        [[ -n "$line" ]] && WANTED_NAMES+=("$line")
    done < "$LIST_FILE"
    [[ ${#WANTED_NAMES[@]} -eq 0 ]] && die "No filenames found in $LIST_FILE"
    log "Loaded ${BOLD}${#WANTED_NAMES[@]}${RESET} filename(s) from $LIST_FILE"
fi



# --------------------------------------------------------------------------- #
# List files from source
# --------------------------------------------------------------------------- #
list_files() {
    local src="$1" type="$2"
    case "$type" in
        local)
            if $RECURSIVE; then
                find "$src" -type f -name "$PATTERN"
            else
                find "$src" -maxdepth 1 -type f -name "$PATTERN"
            fi
            ;;
        ssh)
            local host="${src%%:*}"
            local path="${src#*:}"
            if $RECURSIVE; then
                ssh "$host" "find '$path' -type f -name '$PATTERN'"
            else
                ssh "$host" "find '$path' -maxdepth 1 -type f -name '$PATTERN'"
            fi
            ;;
        xrootd)
            # xrdfs ls, strip the XRD prefix to get the logical path
            local server="${src%%//*}""//"  # e.g. root://xrootd.km3net.de//
            local lpath="/${src#*//}"       # logical path after double-slash
            lpath="/${lpath#/}"
            xrdfs "${server%//}" ls "$lpath" 2>/dev/null \
                | grep -E "${PATTERN//\*/.*}" || true
            ;;
    esac
}

log "Listing files from source…"
ALL_FILES=$(list_files "$SOURCE" "$SRC_TYPE") || die "Failed to list source files."
TOTAL=$(echo "$ALL_FILES" | grep -c . || true)

[[ "$TOTAL" -eq 0 ]] && die "No files matching pattern '${PATTERN}' found in source."
log "Found ${BOLD}${TOTAL}${RESET} matching file(s)."

# --------------------------------------------------------------------------- #
# --run N : sample N distinct run IDs from filenames, populate IDS array
# --------------------------------------------------------------------------- #
if [[ -n "$N_RUNS" ]]; then
    log "Extracting run IDs from filenames…"

    # Per-file: take the basename and find the LAST 4+ digit numeric token.
    # KM3NeT convention puts the run_id after the det_id, so the last match is
    # the one we want. We use bash's =~ rather than awk because mawk (the
    # default `awk` on many cluster nodes) miscompiles `{4,}` as exactly 4.
    ALL_RUN_IDS=$(
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            bn="${f##*/}"
            last=""
            rest="$bn"
            while [[ "$rest" =~ ([0-9]{4,}) ]]; do
                last="${BASH_REMATCH[1]}"
                rest="${rest#*"$last"}"
            done
            [[ -n "$last" ]] && echo "$last"
        done <<< "$ALL_FILES" | sort -u
    )

    n_unique=$(echo "$ALL_RUN_IDS" | grep -c . || true)
    [[ "$n_unique" -eq 0 ]] && die "Could not extract any run IDs from filenames. " \
                                   "(Looked for the last 4+ digit token in each basename.)"

    log "Found ${BOLD}${n_unique}${RESET} distinct run ID(s) in source."

    if [[ "$N_RUNS" -gt "$n_unique" ]]; then
        warn "Requested $N_RUNS runs but only $n_unique available — using all."
        N_RUNS="$n_unique"
    fi

    SELECTED_IDS=$(echo "$ALL_RUN_IDS" | seeded_sample "$SEED" "$N_RUNS")

    mapfile -t IDS < <(echo "$SELECTED_IDS")
    RUN_IDS_SOURCE="sampled"
    log "Sampled ${BOLD}${#IDS[@]}${RESET} run ID(s)."
fi

# --------------------------------------------------------------------------- #
# Selection: explicit list OR full match-set by run IDs OR random sample
# --------------------------------------------------------------------------- #
if [[ ${#WANTED_NAMES[@]} -gt 0 ]]; then
    declare -A AVAIL=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        AVAIL["$f"]=1            # full path as listed
        AVAIL["${f##*/}"]=1      # basename
    done <<< "$ALL_FILES"

    # For each source file, keep it if its path or basename was requested.
    declare -A REQUESTED=()
    for name in "${WANTED_NAMES[@]}"; do
        REQUESTED["$name"]=1
        REQUESTED["${name##*/}"]=1   # tolerate paths in the list file
    done

    SELECTED=$(
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            if [[ -n "${REQUESTED[$f]:-}" || -n "${REQUESTED[${f##*/}]:-}" ]]; then
                echo "$f"
            fi
        done <<< "$ALL_FILES"
    )
    SAMPLE_N=$(echo "$SELECTED" | grep -c . || true)

    [[ "$SAMPLE_N" -eq 0 ]] && die "None of the ${#WANTED_NAMES[@]} listed file(s) were found in source."

    # Warn about listed entries that matched nothing in the source.
    missing=()
    for name in "${WANTED_NAMES[@]}"; do
        if [[ -z "${AVAIL[$name]:-}" && -z "${AVAIL[${name##*/}]:-}" ]]; then
            missing+=("$name")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        if (( ${#missing[@]} <= 20 )); then
            warn "Listed file(s) not found in source (${#missing[@]}): ${missing[*]}"
        else
            warn "Listed file(s) not found in source: ${#missing[@]} of ${#WANTED_NAMES[@]} (first 20: ${missing[*]:0:20}…)"
        fi
    fi

    log "Matched ${BOLD}${SAMPLE_N}${RESET} file(s) from the list of ${#WANTED_NAMES[@]}."
elif [[ ${#IDS[@]} -gt 0 ]]; then
    # Build extended-regex alternation: id1|id2|id3 — escape any regex metas in IDs
    esc_ids=()
    for id in "${IDS[@]}"; do
        esc_ids+=("$(printf '%s' "$id" | sed -e 's/[][\\.^$*+?(){}|/]/\\&/g')")
    done
    ID_RE=$(IFS='|'; echo "${esc_ids[*]}")

    SELECTED=$(echo "$ALL_FILES" | grep -E "$ID_RE" || true)
    SAMPLE_N=$(echo "$SELECTED" | grep -c . || true)

    [[ "$SAMPLE_N" -eq 0 ]] && die "No files matched any of the ${#IDS[@]} run ID(s)."

    missing=$(comm -23 \
        <(printf '%s\n' "${IDS[@]}" | sort -u) \
        <(echo "$matched_ids"))

    if [[ -n "$missing" ]]; then
        n_missing=$(echo "$missing" | grep -c .)
        if (( n_missing <= 20 )); then
            warn "Run IDs with no matching file ($n_missing): $(echo "$missing" | tr '\n' ' ')"
        else
            warn "Run IDs with no matching file: $n_missing of ${#IDS[@]} (first 20: $(echo "$missing" | head -20 | tr '\n' ' ')…)"
        fi
    fi

    log "Matched ${BOLD}${SAMPLE_N}${RESET} file(s) for ${#IDS[@]} run ID(s)."
else
    # Random-sample by count or fraction
    if [[ -n "$N_FILES" ]]; then
        SAMPLE_N="$N_FILES"
    else
        SAMPLE_N=$(awk "BEGIN { n=int($TOTAL * $FRACTION + 0.5); print (n<1)?1:n }")
    fi

    [[ "$SAMPLE_N" -gt "$TOTAL" ]] && {
        warn "Requested $SAMPLE_N but only $TOTAL available — using all."
        SAMPLE_N="$TOTAL"
    }
    log "Sampling ${BOLD}${SAMPLE_N}${RESET} of ${TOTAL} file(s)."

    SELECTED=$(echo "$ALL_FILES" | seeded_sample "$SEED" "$SAMPLE_N")
fi

if (( VERBOSE >= 2 )); then
    log "Selected files:"
    echo "$SELECTED" | while read -r f; do echo "  $f"; done
fi

# --------------------------------------------------------------------------- #
# Transfer
# --------------------------------------------------------------------------- #
TRANSFERRED=0
FAILED=0
START_TIME=$(date +%s)

_exec() {
    (( VERBOSE >= 2 )) && log "  \$ $*"
    if $SHOW_BAR; then "$@" >/dev/null; else "$@"; fi
}

transfer_file() {
    local file="$1"

    # Construct source URI
    case "$SRC_TYPE" in
        local)  src_uri="$file" ;;
        ssh)    src_uri="${SOURCE%%:*}:$file" ;;
        xrootd)
            local server="${SOURCE%%//*}//"
            src_uri="${server}${file}"
            ;;
    esac

    if $DRY_RUN; then
        echo "  [DRY-RUN] would transfer: $src_uri → $DEST"
        return 0
    fi

    # Choose transfer tool based on src/dst type combination
    if [[ "$SRC_TYPE" == "xrootd" || "$DST_TYPE" == "xrootd" ]]; then
        # XRootD → anything or anything → XRootD
        local dst_uri
        case "$DST_TYPE" in
            xrootd) dst_uri="${DEST%/}/$(basename "$file")" ;;
            local)  dst_uri="${DEST%/}/$(basename "$file")" ;;
            ssh)    dst_uri="${DEST}" ;;  # pipe through local for ssh dst
        esac
        _exec xrdcp $XRDCP_OPTS "$src_uri" "$dst_uri"
    elif [[ "$SRC_TYPE" == "local" && "$DST_TYPE" == "local" ]]; then
        mkdir -p "$DEST"
        _exec cp "$file" "${DEST%/}/"
    else
        # SSH source or SSH dest: use rsync
        _exec rsync $RSYNC_OPTS "$src_uri" "$DEST"
    fi
}

# Decide presentation: progress bar only at level 0 and not during a dry-run.
SHOW_BAR=false
if (( VERBOSE == 0 )) && ! $DRY_RUN; then
    SHOW_BAR=true
    # Silence per-file tool chatter so it doesn't fight the overall bar.
    RSYNC_OPTS="${RSYNC_OPTS//--progress/} -q"
    XRDCP_OPTS="$XRDCP_OPTS -s"
fi

log "Starting transfer…"
DONE=0
$SHOW_BAR && draw_progress 0 "$SAMPLE_N" "$START_TIME"

while IFS= read -r file; do
    [[ -z "$file" ]] && continue

    if ! $DRY_RUN; then
        if   (( VERBOSE >= 2 )); then log "Transferring: $file"
        elif (( VERBOSE == 1 )); then log "Transferring: ${file##*/}"
        fi
    fi

    if transfer_file "$file"; then
        TRANSFERRED=$((TRANSFERRED + 1))
        [[ -n "$LOG_FILE" ]] && echo "$(date -u +%FT%TZ) OK  $file" >> "$LOG_FILE"
    else
        $SHOW_BAR && printf '\n' >&2   # break the bar line before the warning
        warn "Failed: ${file##*/}"
        FAILED=$((FAILED + 1))
        [[ -n "$LOG_FILE" ]] && echo "$(date -u +%FT%TZ) ERR $file" >> "$LOG_FILE"
    fi

    DONE=$((DONE + 1))
    $SHOW_BAR && draw_progress "$DONE" "$SAMPLE_N" "$START_TIME"
done <<< "$SELECTED"

$SHOW_BAR && printf '\n' >&2

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
echo ""
echo -e "${BOLD}═══════════════════════════════════════${RESET}"
echo -e "${BOLD} Transfer summary${RESET}"
echo -e "${BOLD}═══════════════════════════════════════${RESET}"
$DRY_RUN && echo -e " Mode        : ${YELLOW}DRY RUN${RESET}"
echo    " Source      : $SOURCE  (${SRC_TYPE})"
echo    " Destination : $DEST  (${DST_TYPE})"
echo    " Pattern     : $PATTERN"
if [[ -n "$LIST_FILE" ]]; then
    echo " File list   : ${#WANTED_NAMES[@]} requested (file: $LIST_FILE)"
fi
if [[ ${#IDS[@]} -gt 0 ]]; then
    case "$RUN_IDS_SOURCE" in
        range)   echo " Run IDs     : ${#IDS[@]} (range: $RUN_IDS)" ;;
        file)    echo " Run IDs     : ${#IDS[@]} (file: $RUN_IDS)" ;;
        sampled) echo " Run IDs     : ${#IDS[@]} (sampled via --run $N_RUNS)" ;;
    esac
fi
echo    " Total found : $TOTAL"
echo    " Sampled     : $SAMPLE_N"
[[ -n "$SEED" ]] && echo " Seed        : $SEED"
echo    " Elapsed     : ${ELAPSED}s"
echo -e " Transferred : ${GREEN}${TRANSFERRED}${RESET}"
[[ "$FAILED" -gt 0 ]] && echo -e " Failed      : ${RED}${FAILED}${RESET}"
echo -e "${BOLD}═══════════════════════════════════════${RESET}"

[[ "$FAILED" -gt 0 ]] && exit 1 || exit 0