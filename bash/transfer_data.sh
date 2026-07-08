#!/usr/bin/env bash
# =============================================================================
# transfer_data.sh — Random file/folder sampler & transfer between devices
#
# Transfers a sample of files (or directories) from a source to a destination.
# Supports local paths, remote SSH hosts, and XRootD (dCache) endpoints, in any
# combination:
#     local <-> local        (cp)
#     local <-> ssh          (rsync over a multiplexed ssh connection)
#     ssh   <-> ssh          (rsync executed on the source host)
#     local <-> xrootd       (xrdcp)
#     xrootd<-> xrootd       (xrdcp)
#     ssh   <-> xrootd       (staged through a local temp dir)
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
N_FILES=""
FRACTION=""
N_RUNS=""
RUN_IDS=""
LIST_FILE=""
PATTERN="*"
SEED=""
DRY_RUN=false
VERBOSE=0
RECURSIVE=false
DIRS_MODE=false
LOG_FILE=""

# Transfer tool options, kept as arrays so they can be extended safely.
RSYNC_ARGS=(-a -z --mkpath --progress)
XRDCP_ARGS=(--parallel 4)

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

need() { command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found in PATH."; }

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
    for ((i = 0; i < n; i++)); do
        j=$(( RANDOM % (total - i) + i ))
        tmp="${lines[i]}"
        lines[i]="${lines[j]}"
        lines[j]="$tmp"
    done
    printf '%s\n' "${lines[@]:0:$n}"
}

fmt_hms() {
    local s=$1 h m
    (( s < 0 )) && s=0
    h=$(( s / 3600 )); m=$(( (s % 3600) / 60 )); s=$(( s % 60 ))
    if (( h > 0 )); then printf '%d:%02d:%02d' "$h" "$m" "$s"
    else printf '%02d:%02d' "$m" "$s"; fi
}

draw_progress() {
    local cur=$1 total=$2 start=$3
    (( total <= 0 )) && total=1
    (( cur > total )) && cur=$total

    local width=30
    local pct=$(( cur * 100 / total ))
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

    local c=$'\033[0;36m' rst=$'\033[0m' clr=$'\033[K'
    printf '\r%s|%s|%s %3d%% %d/%d [%s<%s, %s obj/s]%s' \
        "$c" "$bar" "$rst" "$pct" "$cur" "$total" \
        "$(fmt_hms "$elapsed")" "$eta_str" "$rate_str" "$clr" >&2
}

# --------------------------------------------------------------------------- #
# Usage
# --------------------------------------------------------------------------- #
usage() {
cat <<EOF
${BOLD}transfer_data.sh${RESET} — random file/folder sampler & transfer between devices

${BOLD}USAGE${RESET}
  $(basename "$0") [OPTIONS] <source> <destination>

  Endpoints may be:
    local path         /data/run/
    ssh host           user@host:/data/run/   (or host:/data/run/)
    xrootd (dcache)    root://server:1094//pnfs/data/run/

${BOLD}OPTIONS${RESET}
  -n, --count N        Transfer exactly N items
  -f, --fraction F     Transfer a fraction F of items, e.g. 0.10 for 10%
      --run N          Pick N distinct runs at random from the source
      --run-ids ARG    Transfer all items whose names contain a run ID
                       (ARG is a START-END range or a file of IDs)
  -L, --list FILE      Transfer exactly the items listed in FILE
  -p, --pattern GLOB   Pattern to match, default: '*'
  -d, --dirs           Sample and transfer entire directories instead of files
  -s, --seed INT       Random seed for reproducibility
  -r, --recursive      Recurse into subdirectories (local/SSH sources)
      --dry-run        Print actions without executing transfers
  -v, --verbose        Increase verbosity (repeatable)
  -l, --log FILE       Append transfer log to FILE
  -h, --help           Show this help
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
        -d|--dirs)      DIRS_MODE=true; shift   ;;
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

n_modes=0
[[ -n "$N_FILES"  ]] && n_modes=$((n_modes + 1))
[[ -n "$FRACTION" ]] && n_modes=$((n_modes + 1))
[[ -n "$N_RUNS"   ]] && n_modes=$((n_modes + 1))
[[ -n "$RUN_IDS"  ]] && n_modes=$((n_modes + 1))
[[ -n "$LIST_FILE" ]] && n_modes=$((n_modes + 1))

(( n_modes == 0 )) && die "Specify selection with -n <count>, -f <fraction>, --run <N>, --run-ids <arg>, or --list <file>."
(( n_modes >  1 )) && die "Use only one of -n / -f / --run / --run-ids / --list."

if [[ -n "$N_FILES" ]]; then
    [[ "$N_FILES" =~ ^[0-9]+$ && "$N_FILES" -gt 0 ]] \
        || die "--count: expected a positive integer, got '$N_FILES'."
fi

if [[ -n "$FRACTION" ]]; then
    [[ "$FRACTION" =~ ^0*(\.[0-9]+)?$|^1(\.0+)?$ ]] \
        || die "--fraction: expected a value in (0,1], got '$FRACTION'."
fi

if [[ -n "$N_RUNS" ]]; then
    [[ "$N_RUNS" =~ ^[0-9]+$ && "$N_RUNS" -gt 0 ]] \
        || die "--run: expected a positive integer, got '$N_RUNS'."
fi

if [[ -n "$LIST_FILE" ]]; then
    [[ -f "$LIST_FILE" ]] || die "--list: file '$LIST_FILE' does not exist."
fi

if [[ -n "$RUN_IDS" ]]; then
    if [[ "$RUN_IDS" =~ ^[0-9]+-[0-9]+$ ]] || [[ -f "$RUN_IDS" ]]; then
        :
    else
        die "--run-ids: '$RUN_IDS' is neither a START-END range nor an existing file."
    fi
fi

# --------------------------------------------------------------------------- #
# Detect endpoint type
#   xrootd : root://...
#   ssh    : [user@]host:path   (host part contains no '/' before the colon)
#   local  : anything else. Prefix a local path with ./ if it contains a ':'.
# --------------------------------------------------------------------------- #
detect_type() {
    local path="$1"
    if [[ "$path" == root://* ]]; then
        echo "xrootd"
    elif [[ "$path" == *:* && "${path%%:*}" != */* && "${path%%:*}" != "$path" ]]; then
        echo "ssh"
    else
        echo "local"
    fi
}

# Split an xrootd URL (root://host[:port]//path) into server + path.
# Sets the named-by-caller globals via the two echoed lines.
xrootd_split() {  # <url> -> prints "<server>\n<path>"
    local url="${1#root://}"
    [[ "$url" == *//* ]] || die "Malformed xrootd URL (expected root://host//path): $1"
    local host="${url%%//*}"
    local path="/${url#*//}"
    printf 'root://%s\n%s\n' "$host" "$path"
}

# Convert a shell glob to an (unanchored) ERE for grep, as xrdfs has no glob.
glob2re() { printf '%s' "${1//\*/.*}"; }

SRC_TYPE=$(detect_type "$SOURCE")
DST_TYPE=$(detect_type "$DEST")

log "Source type : ${BOLD}${SRC_TYPE}${RESET}  →  ${SOURCE}"
log "Dest type   : ${BOLD}${DST_TYPE}${RESET}  →  ${DEST}"

# --------------------------------------------------------------------------- #
# Dependency checks (only for the tools this run will actually use)
# --------------------------------------------------------------------------- #
need shuf
[[ "$SRC_TYPE" == ssh || "$DST_TYPE" == ssh ]] && { need ssh; need rsync; }
[[ "$SRC_TYPE" == local || "$DST_TYPE" == local ]] && need cp
{ [[ "$SRC_TYPE" == xrootd || "$DST_TYPE" == xrootd ]]; } && { need xrdcp; need xrdfs; }
# A staged ssh<->xrootd transfer needs both toolchains plus a local hop.
if { [[ "$SRC_TYPE" == ssh && "$DST_TYPE" == xrootd ]] || \
     [[ "$SRC_TYPE" == xrootd && "$DST_TYPE" == ssh ]]; }; then
    need rsync; need ssh; need xrdcp
fi

# --------------------------------------------------------------------------- #
# Pre-split xrootd endpoints (once)
# --------------------------------------------------------------------------- #
XR_SRC_SERVER=""; XR_SRC_PATH=""
XR_DST_SERVER=""; XR_DST_PATH=""
if [[ "$SRC_TYPE" == xrootd ]]; then
    { read -r XR_SRC_SERVER; read -r XR_SRC_PATH; } < <(xrootd_split "$SOURCE")
fi
if [[ "$DST_TYPE" == xrootd ]]; then
    { read -r XR_DST_SERVER; read -r XR_DST_PATH; } < <(xrootd_split "$DEST")
fi

# --------------------------------------------------------------------------- #
# Temp dirs: one for the ssh control socket (connection multiplexing), one for
# staging cross-protocol transfers. Both are cleaned up on exit.
# --------------------------------------------------------------------------- #
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/transfer_data.XXXXXX")"
SSH_MUX_DIR="$TMP_ROOT/mux"
STAGE_DIR="$TMP_ROOT/stage"
mkdir -p "$SSH_MUX_DIR" "$STAGE_DIR"
cleanup() { rm -rf "$TMP_ROOT" 2>/dev/null || true; }
trap cleanup EXIT

# Multiplexed ssh: reuse a single TCP+auth connection for every file, which is
# the main win when moving many small files over ssh.
SSH_OPTS=(-o "ControlMaster=auto" -o "ControlPath=$SSH_MUX_DIR/%r@%h:%p" -o "ControlPersist=30")
SSH_CMD="ssh ${SSH_OPTS[*]}"

# --------------------------------------------------------------------------- #
# Load run IDs (if given)
# --------------------------------------------------------------------------- #
IDS=()
RUN_IDS_SOURCE=""
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
# Load explicit list (if given)
# --------------------------------------------------------------------------- #
WANTED_NAMES=()
if [[ -n "$LIST_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] && WANTED_NAMES+=("$line")
    done < "$LIST_FILE"
    [[ ${#WANTED_NAMES[@]} -eq 0 ]] && die "No filenames found in $LIST_FILE"
    log "Loaded ${BOLD}${#WANTED_NAMES[@]}${RESET} filename(s) from $LIST_FILE"
fi

# --------------------------------------------------------------------------- #
# List items from source
# --------------------------------------------------------------------------- #
list_files() {
    local src="$1" type="$2"
    local item_type="f"
    $DIRS_MODE && item_type="d"

    case "$type" in
        local)
            if $RECURSIVE; then
                find "$src" -mindepth 1 -type "$item_type" -name "$PATTERN"
            else
                find "$src" -mindepth 1 -maxdepth 1 -type "$item_type" -name "$PATTERN"
            fi
            ;;
        ssh)
            local host="${src%%:*}"
            local path="${src#*:}"
            local depth="-maxdepth 1"
            $RECURSIVE && depth=""
            ssh "${SSH_OPTS[@]}" "$host" \
                "find '$path' -mindepth 1 $depth -type '$item_type' -name '$PATTERN'"
            ;;
        xrootd)
            local server="$XR_SRC_SERVER" lpath="$XR_SRC_PATH"
            if $DIRS_MODE; then
                # xrdfs ls doesn't include the parent dir; filter dir entries.
                xrdfs "$server" ls -l "$lpath" 2>/dev/null \
                    | awk '/^d/ {print $NF}' | grep -E "$(glob2re "$PATTERN")" || true
            else
                xrdfs "$server" ls "$lpath" 2>/dev/null \
                    | grep -E "$(glob2re "$PATTERN")" || true
            fi
            ;;
    esac
}

log "Listing items from source…"
ALL_FILES=$(list_files "$SOURCE" "$SRC_TYPE") || die "Failed to list source items."
TOTAL=$(echo "$ALL_FILES" | grep -c . || true)

[[ "$TOTAL" -eq 0 ]] && die "No matching items found in source."
log "Found ${BOLD}${TOTAL}${RESET} matching item(s)."

# --------------------------------------------------------------------------- #
# --run N : sample N distinct run IDs from filenames
# --------------------------------------------------------------------------- #
if [[ -n "$N_RUNS" ]]; then
    log "Extracting run IDs from item names…"
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
    [[ "$n_unique" -eq 0 ]] && die "Could not extract any run IDs from filenames."

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
        AVAIL["$f"]=1
        AVAIL["${f##*/}"]=1
    done <<< "$ALL_FILES"

    declare -A REQUESTED=()
    for name in "${WANTED_NAMES[@]}"; do
        REQUESTED["$name"]=1
        REQUESTED["${name##*/}"]=1
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

    [[ "$SAMPLE_N" -eq 0 ]] && die "None of the ${#WANTED_NAMES[@]} listed item(s) were found in source."

    missing=()
    for name in "${WANTED_NAMES[@]}"; do
        if [[ -z "${AVAIL[$name]:-}" && -z "${AVAIL[${name##*/}]:-}" ]]; then
            missing+=("$name")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        if (( ${#missing[@]} <= 20 )); then
            warn "Listed item(s) not found in source (${#missing[@]}): ${missing[*]}"
        else
            warn "Listed item(s) not found in source: ${#missing[@]} of ${#WANTED_NAMES[@]} (first 20: ${missing[*]:0:20}…)"
        fi
    fi

    log "Matched ${BOLD}${SAMPLE_N}${RESET} item(s) from the list of ${#WANTED_NAMES[@]}."
elif [[ ${#IDS[@]} -gt 0 ]]; then
    esc_ids=()
    for id in "${IDS[@]}"; do
        esc_ids+=("$(printf '%s' "$id" | sed -e 's/[][\\.^$*+?(){}|/]/\\&/g')")
    done
    ID_RE=$(IFS='|'; echo "${esc_ids[*]}")

    # Match run IDs against the basename only — matching the full path would
    # false-positive on digits in the leading directories.
    SELECTED=$(
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            [[ "${f##*/}" =~ $ID_RE ]] && echo "$f"
        done <<< "$ALL_FILES"
        true   # keep the subshell's exit status 0 under set -e
    )
    SAMPLE_N=$(echo "$SELECTED" | grep -c . || true)

    [[ "$SAMPLE_N" -eq 0 ]] && die "No items matched any of the ${#IDS[@]} run ID(s)."
    log "Matched ${BOLD}${SAMPLE_N}${RESET} item(s) for ${#IDS[@]} run ID(s)."
else
    if [[ -n "$N_FILES" ]]; then
        SAMPLE_N="$N_FILES"
    else
        SAMPLE_N=$(awk "BEGIN { n=int($TOTAL * $FRACTION + 0.5); print (n<1)?1:n }")
    fi

    [[ "$SAMPLE_N" -gt "$TOTAL" ]] && {
        warn "Requested $SAMPLE_N but only $TOTAL available — using all."
        SAMPLE_N="$TOTAL"
    }
    log "Sampling ${BOLD}${SAMPLE_N}${RESET} of ${TOTAL} item(s)."

    SELECTED=$(echo "$ALL_FILES" | seeded_sample "$SEED" "$SAMPLE_N")
fi

if (( VERBOSE >= 2 )); then
    log "Selected items:"
    echo "$SELECTED" | while read -r f; do echo "  $f"; done
fi

# --------------------------------------------------------------------------- #
# Transfer
# --------------------------------------------------------------------------- #
TRANSFERRED=0
FAILED=0
START_TIME=$(date +%s)

SHOW_BAR=false
if (( VERBOSE == 0 )) && ! $DRY_RUN; then
    SHOW_BAR=true
    _q=(); for _a in "${RSYNC_ARGS[@]}"; do [[ "$_a" == --progress ]] || _q+=("$_a"); done
    RSYNC_ARGS=("${_q[@]}" -q); unset _q _a
    XRDCP_ARGS+=(-s)
fi
$DIRS_MODE && XRDCP_ARGS+=(-r)

if [[ "$DST_TYPE" == local ]]; then
    mkdir -p "$DEST"
fi

WARNED_RR=false

_exec() {
    (( VERBOSE >= 2 )) && log "  \$ $*"
    if $SHOW_BAR; then "$@" >/dev/null; else "$@"; fi
}

# ---- transfer primitives (each has at most one non-local endpoint) -------- #

# Copy one local item into the local DEST directory.
cp_local() {
    local file="$1" flags=(-p)
    $DIRS_MODE && flags+=(-r)
    _exec cp "${flags[@]}" -- "$file" "${DEST%/}/"
}

# Pull one remote item (ssh|xrootd source) into a local destination directory.
pull_to_local() {  # <file> <dstdir>
    local file="$1" dstdir="$2" base="${file##*/}"
    case "$SRC_TYPE" in
        ssh)    _exec rsync "${RSYNC_ARGS[@]}" -e "$SSH_CMD" "${SOURCE%%:*}:$file" "${dstdir%/}/" ;;
        xrootd) mkdir -p "$dstdir"
                _exec xrdcp "${XRDCP_ARGS[@]}" "${XR_SRC_SERVER}/${file}" "${dstdir%/}/$base" ;;
    esac
}

# Push one local item to the remote DEST (ssh|xrootd destination).
push_from_local() {  # <localpath>
    local lp="$1" base="${lp##*/}"
    case "$DST_TYPE" in
        ssh)    _exec rsync "${RSYNC_ARGS[@]}" -e "$SSH_CMD" "$lp" "${DEST%/}/" ;;
        xrootd) _exec xrdcp "${XRDCP_ARGS[@]}" "$lp" "${XR_DST_SERVER}/${XR_DST_PATH%/}/$base" ;;
    esac
}

# Direct xrootd->xrootd copy.
xrdcp_xx() {  # <file>
    local file="$1" base="${file##*/}"
    _exec xrdcp "${XRDCP_ARGS[@]}" \
        "${XR_SRC_SERVER}/${file}" "${XR_DST_SERVER}/${XR_DST_PATH%/}/$base"
}

rsync_rr() {  # <file>
    local file="$1" srchost="${SOURCE%%:*}"
    if ! $WARNED_RR; then
        warn "ssh→ssh: rsync runs on '$srchost'; it must be able to reach '${DEST%%:*}'."
        WARNED_RR=true
    fi
    _exec ssh "${SSH_OPTS[@]}" "$srchost" \
        "rsync -az --mkpath -q -- '$file' '${DEST}'"
}

transfer_file() {
    local file="$1" base="${file##*/}"

    if $DRY_RUN; then
        echo "  [DRY-RUN] would transfer: ${SRC_TYPE}:${file} → ${DST_TYPE}:${DEST}"
        return 0
    fi

    case "${SRC_TYPE}:${DST_TYPE}" in
        local:local)   cp_local "$file" ;;
        local:*)       push_from_local "$file" ;;
        *:local)       pull_to_local "$file" "$DEST" ;;
        ssh:ssh)       rsync_rr "$file" ;;
        xrootd:xrootd) xrdcp_xx "$file" ;;
        *)  # cross-protocol remote↔remote (ssh↔xrootd): stage via local temp
            local staged="$STAGE_DIR/$base"
            rm -rf "$staged"
            pull_to_local "$file" "$STAGE_DIR" && push_from_local "$staged"
            local rc=$?
            rm -rf "$staged"
            return $rc
            ;;
    esac
}

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
        $SHOW_BAR && printf '\n' >&2
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
