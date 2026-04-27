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
PATTERN="*"         # glob/filter pattern for file selection
SEED=""             # optional random seed for reproducibility
DRY_RUN=false
VERBOSE=false
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

# --------------------------------------------------------------------------- #
# Usage
# --------------------------------------------------------------------------- #
usage() {
cat <<EOF
${BOLD}sample_transfer.sh${RESET} — random file sampler & transfer for km3tipi

${BOLD}USAGE${RESET}
  $(basename "$0") [OPTIONS] <source> <destination>

${BOLD}OPTIONS${RESET}
  -n, --count N        Transfer exactly N files (mutually exclusive with -f)
  -f, --fraction F     Transfer a fraction F of files, e.g. 0.10 for 10%
  -p, --pattern GLOB   File pattern to match, default: '*'
  -s, --seed INT       Random seed for reproducibility
  -r, --recursive      Recurse into subdirectories (local/SSH sources)
      --dry-run        Print actions without executing transfers
  -v, --verbose        Verbose output
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
        -p|--pattern)   PATTERN="$2";   shift 2 ;;
        -s|--seed)      SEED="$2";      shift 2 ;;
        -r|--recursive) RECURSIVE=true; shift   ;;
        --dry-run)      DRY_RUN=true;   shift   ;;
        -v|--verbose)   VERBOSE=true;   shift   ;;
        -l|--log)       LOG_FILE="$2";  shift 2 ;;
        -h|--help)      usage; exit 0           ;;
        -*)             die "Unknown option: $1" ;;
        *)              POSITIONAL+=("$1"); shift ;;
    esac
done

[[ ${#POSITIONAL[@]} -eq 2 ]] || { usage; die "Exactly 2 positional args required: <source> <destination>"; }
SOURCE="${POSITIONAL[0]}"
DEST="${POSITIONAL[1]}"

[[ -n "$N_FILES" && -n "$FRACTION" ]] && die "Use either -n or -f, not both."
[[ -z "$N_FILES" && -z "$FRACTION" ]] && die "Specify sample size with -n <count> or -f <fraction>."

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
# Determine sample count
# --------------------------------------------------------------------------- #
if [[ -n "$N_FILES" ]]; then
    SAMPLE_N="$N_FILES"
else
    # awk for float arithmetic
    SAMPLE_N=$(awk "BEGIN { n=int($TOTAL * $FRACTION + 0.5); print (n<1)?1:n }")
fi

[[ "$SAMPLE_N" -gt "$TOTAL" ]] && { warn "Requested $SAMPLE_N but only $TOTAL available — using all."; SAMPLE_N="$TOTAL"; }
log "Sampling ${BOLD}${SAMPLE_N}${RESET} of ${TOTAL} file(s)."

# --------------------------------------------------------------------------- #
# Random sampling (with optional seed)
# --------------------------------------------------------------------------- #
if [[ -n "$SEED" ]]; then
    SELECTED=$(echo "$ALL_FILES" | awk -v seed="$SEED" -v n="$SAMPLE_N" '
        BEGIN { srand(seed) }
        { lines[NR] = $0 }
        END {
            total = NR
            for (i = total; i > total - n; i--) {
                j = int(rand() * i) + 1
                tmp = lines[i]; lines[i] = lines[j]; lines[j] = tmp
            }
            for (k = total - n + 1; k <= total; k++) print lines[k]
        }')
else
    SELECTED=$(echo "$ALL_FILES" | shuf -n "$SAMPLE_N")
fi

if $VERBOSE; then
    log "Selected files:"
    echo "$SELECTED" | while read -r f; do echo "  $f"; done
fi

# --------------------------------------------------------------------------- #
# Transfer
# --------------------------------------------------------------------------- #
TRANSFERRED=0
FAILED=0
START_TIME=$(date +%s)

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
        xrdcp $XRDCP_OPTS "$src_uri" "$dst_uri"
    elif [[ "$SRC_TYPE" == "local" && "$DST_TYPE" == "local" ]]; then
        mkdir -p "$DEST"
        cp "$file" "${DEST%/}/"
    else
        # SSH source or SSH dest: use rsync
        rsync $RSYNC_OPTS "$src_uri" "$DEST"
    fi
}

log "Starting transfer…"
echo "$SELECTED" | while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    $VERBOSE && log "Transferring: $file"
    if transfer_file "$file"; then
        TRANSFERRED=$((TRANSFERRED + 1))
        [[ -n "$LOG_FILE" ]] && echo "$(date -u +%FT%TZ) OK  $file" >> "$LOG_FILE"
    else
        warn "Failed: $file"
        FAILED=$((FAILED + 1))
        [[ -n "$LOG_FILE" ]] && echo "$(date -u +%FT%TZ) ERR $file" >> "$LOG_FILE"
    fi
done

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
echo    " Total found : $TOTAL"
echo    " Sampled     : $SAMPLE_N"
[[ -n "$SEED" ]] && echo " Seed        : $SEED"
echo    " Elapsed     : ${ELAPSED}s"
echo -e " Transferred : ${GREEN}${TRANSFERRED}${RESET}"
[[ "$FAILED" -gt 0 ]] && echo -e " Failed      : ${RED}${FAILED}${RESET}"
echo -e "${BOLD}═══════════════════════════════════════${RESET}"

[[ "$FAILED" -gt 0 ]] && exit 1 || exit 0