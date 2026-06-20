#!/usr/bin/env bash
# =============================================================================
# monitor_jobs.sh — Snakemake pipeline + scheduler monitor for km3tipi
#
# Combines two views into one screen:
#   1. Pipeline matrix    rules × samples, with per-state counts derived from
#                         output files, sentinels, log files, and queue.
#   2. Scheduler queue    live snapshot of squeue / condor_q for jobs related
#                         to this run.
#
# Auto-detects SLURM (squeue) or HTCondor (condor_q); falls back to
# "filesystem-only" mode if neither is on PATH.
#
# Usage:
#   monitor_jobs.sh [OPTIONS]
#
# Examples:
#   monitor_jobs.sh                                # one-shot snapshot
#   monitor_jobs.sh --watch                        # live, default 5s refresh
#   monitor_jobs.sh --watch -i 2                   # 2s refresh
#   monitor_jobs.sh -d results/KM3NeT_00000117     # explicit results dir
#   monitor_jobs.sh --scheduler htcondor           # force scheduler
#   monitor_jobs.sh --no-color                     # for piping to file
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
CONFIG="config/pipeline.yaml"
RESULTS_DIR=""              # resolved later: CLI arg > config-derived
WATCH=false
INTERVAL=5
SCHEDULER=""                # "" = auto-detect; or "slurm"|"htcondor"|"none"
USER_NAME="${USER:-$(id -un)}"
USE_COLOR=true

# Stages, in pipeline order. Must match rule names in the Snakefile.
STAGES=(prepare discover convert validate ml_manifest metadata)

# --------------------------------------------------------------------------- #
# Colours (defined unconditionally; stripped after parse if --no-color)
# --------------------------------------------------------------------------- #
RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'; BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'
BOLD=$'\033[1m';   DIM=$'\033[2m';      RESET=$'\033[0m'

log()  { echo -e "${CYAN}[INFO]${RESET}  $*" >&2; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

# --------------------------------------------------------------------------- #
# Usage
# --------------------------------------------------------------------------- #
usage() {
cat <<EOF
${BOLD}monitor_jobs.sh${RESET} — pipeline + scheduler monitor for km3tipi

${BOLD}USAGE${RESET}
  $(basename "$0") [OPTIONS]

${BOLD}OPTIONS${RESET}
  -c, --config FILE       Path to pipeline.yaml  (default: config/pipeline.yaml)
  -d, --results-dir DIR   Override results directory (otherwise inferred from config)
  -w, --watch             Refresh continuously instead of one-shot snapshot
  -i, --interval SEC      Refresh interval for --watch  (default: 5)
      --scheduler NAME    Force scheduler: 'slurm', 'htcondor', or 'none'
                          Default: auto-detect (slurm > htcondor > none)
  -u, --user NAME         Username for queue queries  (default: \$USER)
      --no-color          Disable ANSI colours (for piping/logging)
  -h, --help              Show this help

${BOLD}STATES${RESET}
  ${GREEN}D${RESET}one    output file present (or sentinel for validate/ml_manifest)
  ${BLUE}R${RESET}unning queue entry matches this work unit
  ${RED}F${RESET}ailed  log file exists, no output, no queue entry
  ${DIM}P${RESET}ending no log, no output, no queue entry
EOF
}

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)        CONFIG="$2";       shift 2 ;;
        -d|--results-dir)   RESULTS_DIR="$2";  shift 2 ;;
        -w|--watch)         WATCH=true;        shift   ;;
        -i|--interval)      INTERVAL="$2";     shift 2 ;;
        --scheduler)        SCHEDULER="$2";    shift 2 ;;
        -u|--user)          USER_NAME="$2";    shift 2 ;;
        --no-color)         USE_COLOR=false;   shift   ;;
        -h|--help)          usage; exit 0              ;;
        -*)                 die "Unknown option: $1"   ;;
        *)                  die "Unexpected positional argument: $1" ;;
    esac
done

if ! $USE_COLOR; then
    RED=""; YELLOW=""; GREEN=""; CYAN=""; BLUE=""; MAGENTA=""
    BOLD=""; DIM=""; RESET=""
fi

[[ -f "$CONFIG" ]] || die "Config not found: $CONFIG"

if [[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -gt 0 ]]; then :
else die "--interval must be a positive integer (got '$INTERVAL')"
fi

case "${SCHEDULER}" in
    ""|slurm|htcondor|none) : ;;
    *) die "--scheduler must be one of: slurm, htcondor, none (got '$SCHEDULER')" ;;
esac

# --------------------------------------------------------------------------- #
# Dependency check
# --------------------------------------------------------------------------- #
command -v python3 &>/dev/null || die "python3 is required."

# --------------------------------------------------------------------------- #
# Resolve results directory
# --------------------------------------------------------------------------- #
PIPELINE_CONFIG="$(dirname "${BASH_SOURCE[0]}")/../scripts/pipeline_config.py"
[[ -f "$PIPELINE_CONFIG" ]] || die "pipeline_config.py not found at $PIPELINE_CONFIG"

if [[ -z "$RESULTS_DIR" ]]; then
    RESULTS_DIR=$(python3 "$PIPELINE_CONFIG" -c "$CONFIG" results-dir) \
        || die "Failed to resolve results dir from $CONFIG."
    [[ -z "$RESULTS_DIR" ]] && die \
        "Could not infer results directory from $CONFIG. Pass -d <dir>."
fi


# --------------------------------------------------------------------------- #
# Auto-detect scheduler
# --------------------------------------------------------------------------- #
detect_scheduler() {
    if command -v squeue   &>/dev/null; then echo "slurm";    return; fi
    if command -v condor_q &>/dev/null; then echo "htcondor"; return; fi
    echo "none"
}

if [[ -z "$SCHEDULER" ]]; then
    SCHEDULER=$(detect_scheduler)
fi

case "$SCHEDULER" in
    slurm)    command -v squeue   &>/dev/null || die "squeue not on PATH (slurm forced).";;
    htcondor) command -v condor_q &>/dev/null || die "condor_q not on PATH (htcondor forced).";;
esac

# --------------------------------------------------------------------------- #
# Parse samples + n_jobs from config
# --------------------------------------------------------------------------- #
SAMPLE_INFO=$(python3 "$PIPELINE_CONFIG" -c "$CONFIG" samples --format njobs) \
    || die "Failed to parse samples from $CONFIG."

[[ -z "$SAMPLE_INFO" ]] && die "No samples found in $CONFIG."

declare -a SAMPLES=()
declare -A SAMPLE_NJOBS=()
while read -r name n; do
    [[ -z "$name" ]] && continue
    SAMPLES+=("$name")
    SAMPLE_NJOBS["$name"]="$n"
done <<< "$SAMPLE_INFO"

# --------------------------------------------------------------------------- #
# Filesystem probe
#
# Running detection here is filesystem-only (mtime). The queue probe later
# upgrades units from F→R when there's a queue entry that matches.
# --------------------------------------------------------------------------- #

PARQUET_DIR="$RESULTS_DIR/parquet"
ALIAS_DIR="$RESULTS_DIR/aliases"
MANIFEST_DIR="$RESULTS_DIR/manifests"
LOG_DIR="$RESULTS_DIR/logs"
ML_DIR="$RESULTS_DIR/ml"

# Trees and ML datasets, also from config.
declare -a TREES=()
declare -a DATASETS=()
mapfile -t TREES    < <(python3 "$PIPELINE_CONFIG" -c "$CONFIG" trees       --format lines)
mapfile -t DATASETS < <(python3 "$PIPELINE_CONFIG" -c "$CONFIG" ml-datasets --format lines)

declare -A STATE_COUNTS=()       # "<rule>|<sample>|<state>" -> count
declare -A STATE_TOTAL=()        # "<rule>|<sample>"         -> expected total

# Initialize all (rule, sample) cells to zero so missing rows render as P=0.
init_cell() {
    local rule="$1" sample="$2" total="$3"
    STATE_TOTAL["${rule}|${sample}"]="$total"
    for s in D R F P; do STATE_COUNTS["${rule}|${sample}|${s}"]=0; done
}

# Bump a state count.
bump() {
    local rule="$1" sample="$2" state="$3"
    local k="${rule}|${sample}|${state}"
    STATE_COUNTS["$k"]=$(( ${STATE_COUNTS["$k"]:-0} + 1 ))
}

# Classify a single (rule, unit) by its expected output path + log path.
# Args: rule, sample, output_path, log_path
# Sets state P/F/D — never R; queue probe handles R.
classify() {
    local rule="$1" sample="$2" out="$3" lg="$4"
    if [[ -e "$out" ]]; then
        bump "$rule" "$sample" D
    elif [[ -f "$lg" ]]; then
        bump "$rule" "$sample" F
    else
        bump "$rule" "$sample" P
    fi
}

probe_filesystem() {
    # Reset counters every refresh
    STATE_COUNTS=()
    STATE_TOTAL=()

    for sample in "${SAMPLES[@]}"; do
        local n_chunks="${SAMPLE_NJOBS[$sample]}"

        # prepare: 1 unit per sample, output is the manifest dir
        init_cell prepare "$sample" 1
        classify prepare "$sample" \
            "$MANIFEST_DIR/$sample" \
            "$LOG_DIR/prepare/$sample.log"

        # discover: one alias JSON per tree
        init_cell discover "$sample" "${#TREES[@]}"
        for tree in "${TREES[@]}"; do
            classify discover "$sample" \
                "$ALIAS_DIR/$sample/${tree}_aliases.json" \
                "$LOG_DIR/discover/${sample}_${tree}.log"
        done

        # convert: n_chunks parquet files
        init_cell convert "$sample" "$n_chunks"
        for ((i = 0; i < n_chunks; i++)); do
            classify convert "$sample" \
                "$PARQUET_DIR/$sample/chunk_${i}.parquet" \
                "$LOG_DIR/convert/${sample}_chunk${i}.log"
        done

        # validate: 1 sentinel per sample
        init_cell validate "$sample" 1
        classify validate "$sample" \
            "$PARQUET_DIR/$sample/_validated" \
            "$LOG_DIR/validate/$sample.log"
    done

    # ml_manifest + metadata: per-dataset, indexed under "<dataset>" pseudo-sample
    for ds in "${DATASETS[@]}"; do
        init_cell ml_manifest "$ds" 1
        classify ml_manifest "$ds" \
            "$ML_DIR/$ds/manifest.json" \
            "$LOG_DIR/ml_manifest/$ds.log"

        init_cell metadata "$ds" 1
        classify metadata "$ds" \
            "$ML_DIR/$ds/metadata.json" \
            "$LOG_DIR/metadata/$ds.log"
    done
}

# --------------------------------------------------------------------------- #
# Queue probe
#
# For each scheduler, collect entries belonging to the user. For each entry,
# extract two things:
#   1. Job name (snakejob.<rule>.<jobid>) — for rule attribution
#   2. Log path — for sample/chunk attribution (since wildcards aren't in the
#      job name)
# Bump the matching cell from P/F → R.
# --------------------------------------------------------------------------- #

QUEUE_RAW=""           # raw queue text for the side panel
QUEUE_COUNT=0
QUEUE_RUN=0
QUEUE_PEND=0
QUEUE_HOLD=0

# Convert any matched queue entry to a Running bump; also undo prior P/F.
mark_running() {
    local rule="$1" sample="$2"
    local pk="${rule}|${sample}|P"
    local fk="${rule}|${sample}|F"
    local rk="${rule}|${sample}|R"

    # We can't tell which specific chunk is running without parsing logs, so
    # give priority to converting an F first (it's wrong by definition: a log
    # exists but the job is actually still alive, e.g. retry), then a P.
    if (( ${STATE_COUNTS["$fk"]:-0} > 0 )); then
        STATE_COUNTS["$fk"]=$(( STATE_COUNTS["$fk"] - 1 ))
    elif (( ${STATE_COUNTS["$pk"]:-0} > 0 )); then
        STATE_COUNTS["$pk"]=$(( STATE_COUNTS["$pk"] - 1 ))
    fi
    STATE_COUNTS["$rk"]=$(( ${STATE_COUNTS["$rk"]:-0} + 1 ))
}

# Given a log path, return "rule sample" by matching the path against the
# known LOG_DIR layout: $LOG_DIR/<rule>/<sample>{,_<tree>,_chunk<N>}.log
attribute_from_log() {
    local lg="$1"
    [[ -z "$lg" ]] && return
    [[ "$lg" != "$LOG_DIR/"* ]] && return
    local rest="${lg#$LOG_DIR/}"
    local rule="${rest%%/*}"
    local fname="${rest#*/}"
    fname="${fname%.log}"

    # Strip _chunkN or _<tree> suffixes to get the sample name
    local sample="$fname"
    sample="${sample%_chunk*}"
    case "$rule" in
        discover)
            # filename is "<sample>_<tree>" — strip last _<token>
            sample="${sample%_*}"
            ;;
    esac

    echo "$rule $sample"
}

probe_queue_slurm() {
    QUEUE_RAW=""
    QUEUE_COUNT=0; QUEUE_RUN=0; QUEUE_PEND=0; QUEUE_HOLD=0

    # JOBID|STATE|NAME|STDOUT
    local raw
    raw=$(squeue -h -u "$USER_NAME" -o "%i|%T|%j|%o" 2>/dev/null) || raw=""
    [[ -z "$raw" ]] && return

    QUEUE_RAW="$raw"
    while IFS='|' read -r jobid state name stdout; do
        [[ -z "$jobid" ]] && continue
        QUEUE_COUNT=$(( QUEUE_COUNT + 1 ))
        case "$state" in
            RUNNING)              QUEUE_RUN=$((  QUEUE_RUN + 1 )) ;;
            PENDING|CONFIGURING)  QUEUE_PEND=$(( QUEUE_PEND + 1 )) ;;
            *HOLD*|SUSPENDED)     QUEUE_HOLD=$(( QUEUE_HOLD + 1 )) ;;
        esac

        [[ "$state" != "RUNNING" ]] && continue

        # Attribution: prefer log path (--log= in shell; reflected in stdout=%o)
        local rs
        rs=$(attribute_from_log "$stdout")
        if [[ -n "$rs" ]]; then
            mark_running $rs
        fi
    done <<< "$raw"
}

probe_queue_htcondor() {
    QUEUE_RAW=""
    QUEUE_COUNT=0; QUEUE_RUN=0; QUEUE_PEND=0; QUEUE_HOLD=0

    # condor_q -json is the only sane output. Parse with python.
    local raw
    raw=$(condor_q "$USER_NAME" -json 2>/dev/null) || raw=""
    [[ -z "$raw" || "$raw" == "[]" ]] && return

    # Emit "<state>|<jobname>|<logpath>" rows + a summary line up top.
    local parsed
    parsed=$(python3 - <<PYEOF
import json, sys
data = json.loads("""$raw""") if """$raw""".strip() else []
status_map = {1:"PENDING",2:"RUNNING",3:"REMOVED",4:"COMPLETED",5:"HELD",6:"TRANSFERRING_OUTPUT",7:"SUSPENDED"}
total = run = pend = hold = 0
rows = []
for j in data:
    s  = status_map.get(j.get("JobStatus"), "UNKNOWN")
    n  = j.get("JobBatchName") or j.get("Cmd","") or ""
    lg = j.get("UserLog") or j.get("Out") or ""
    total += 1
    if   s == "RUNNING": run  += 1
    elif s == "PENDING": pend += 1
    elif s == "HELD":    hold += 1
    rows.append(f"{s}|{n}|{lg}")
print(f"#{total}|{run}|{pend}|{hold}")
for r in rows:
    print(r)
PYEOF
)
    [[ -z "$parsed" ]] && return

    QUEUE_RAW="$parsed"
    while IFS='|' read -r f1 f2 f3 f4; do
        if [[ "$f1" == \#* ]]; then
            QUEUE_COUNT="${f1#\#}"
            QUEUE_RUN="$f2"; QUEUE_PEND="$f3"; QUEUE_HOLD="$f4"
            continue
        fi
        local state="$f1" name="$f2" lg="$f3"
        [[ "$state" != "RUNNING" ]] && continue

        local rs
        rs=$(attribute_from_log "$lg")
        if [[ -n "$rs" ]]; then
            mark_running $rs
        fi
    done <<< "$parsed"
}

probe_queue() {
    case "$SCHEDULER" in
        slurm)    probe_queue_slurm    ;;
        htcondor) probe_queue_htcondor ;;
        none)     QUEUE_RAW=""; QUEUE_COUNT=0; QUEUE_RUN=0; QUEUE_PEND=0; QUEUE_HOLD=0 ;;
    esac
}

# --------------------------------------------------------------------------- #
# Renderer — pipeline matrix on the left, queue panel on the right
# --------------------------------------------------------------------------- #

# Width of one matrix cell's *content* (no surrounding padding). 6 chars
# fits "NN/NN" plus a one-char marker, in plain ASCII so terminal width
# always equals byte count.
CELL_W=6

# Render one cell to stdout, exactly CELL_W ASCII characters wide. The
# marker uses ASCII (.=pending, *=running, X=failed, ==done) so column
# alignment is preserved across terminals that mishandle East-Asian-wide
# Unicode. Colours convey the state more strongly anyway.
fmt_cell() {
    local rule="$1" sample="$2"
    local total="${STATE_TOTAL[${rule}|${sample}]:-0}"
    local d="${STATE_COUNTS[${rule}|${sample}|D]:-0}"
    local r="${STATE_COUNTS[${rule}|${sample}|R]:-0}"
    local f="${STATE_COUNTS[${rule}|${sample}|F]:-0}"

    if (( total == 0 )); then
        printf "${DIM}%-${CELL_W}s${RESET}" "  -  "
        return
    fi

    local marker color
    if   (( f > 0 ));      then color="$RED";   marker="X"
    elif (( r > 0 ));      then color="$BLUE";  marker="*"
    elif (( d == total )); then color="$GREEN"; marker="="
    else                        color="$DIM";   marker="."
    fi
    # 6 visible chars: "NN/NN<marker>" -> e.g. " 2/ 4X"
    printf "${color}%2d/%-2d%s${RESET}" "$d" "$total" "$marker"
}

# Returns max(8, longest sample name) for the leftmost column.
matrix_label_width() {
    local w=8
    for s in "${SAMPLES[@]}" "${DATASETS[@]}"; do
        (( ${#s} > w )) && w=${#s}
    done
    echo "$w"
}

# Render a sample/dataset row. Args: label, list of (rule, applies?) pairs
# is too awkward in bash, so we just walk STAGES and pick what to print.
# Args:  $1 = label width, $2 = label, $3 = entity kind (sample|dataset)
render_row() {
    local lw="$1" label="$2" kind="$3" stage
    printf "  %-*s" "$lw" "$label"
    for stage in "${STAGES[@]}"; do
        printf "  "
        case "$kind:$stage" in
            sample:ml_manifest|sample:metadata|dataset:prepare|dataset:discover|dataset:convert|dataset:validate)
                printf "${DIM}%-${CELL_W}s${RESET}" "  -  "
                ;;
            *)
                fmt_cell "$stage" "$label"
                ;;
        esac
    done
    printf "\n"
}

render_matrix() {
    local lw stage
    lw=$(matrix_label_width)

    echo -e "${BOLD} pipeline${RESET}  ${DIM}(done/total — = all done · * running · X has failed · . pending)${RESET}"

    # Header: stage names, padded to CELL_W (or longer if the name is)
    printf "  %-*s" "$lw" ""
    for stage in "${STAGES[@]}"; do
        printf "  %-${CELL_W}s" "${stage:0:$CELL_W}"
    done
    printf "\n"

    for sample in "${SAMPLES[@]}"; do
        render_row "$lw" "$sample" sample
    done

    if (( ${#DATASETS[@]} > 0 )); then
        echo
        for ds in "${DATASETS[@]}"; do
            render_row "$lw" "$ds" dataset
        done
    fi
}

render_queue() {
    echo -e "${BOLD} scheduler${RESET}  ${DIM}(${SCHEDULER}${RESET}${DIM}, user=${USER_NAME})${RESET}"
    if [[ "$SCHEDULER" == "none" ]]; then
        echo "  ${DIM}no scheduler available — pipeline view only${RESET}"
        return
    fi

    printf "  total=%d   ${BLUE}running=%d${RESET}   pending=%d" \
        "$QUEUE_COUNT" "$QUEUE_RUN" "$QUEUE_PEND"
    if (( QUEUE_HOLD > 0 )); then
        printf "   ${YELLOW}held=%d${RESET}" "$QUEUE_HOLD"
    fi
    echo
    echo

    if (( QUEUE_COUNT == 0 )); then
        echo "  ${DIM}(queue empty)${RESET}"
        return
    fi

    # Show up to 12 entries with a short summary line each
    local shown=0
    if [[ "$SCHEDULER" == "slurm" ]]; then
        printf "  %-9s %-10s %-30s\n" "JOBID" "STATE" "NAME"
        while IFS='|' read -r jobid state name stdout; do
            [[ -z "$jobid" ]] && continue
            local color="$DIM"
            case "$state" in
                RUNNING) color="$BLUE"  ;;
                PENDING) color=""       ;;
                *HOLD*)  color="$YELLOW";;
            esac
            local short_name="${name:0:30}"
            printf "  %-9s ${color}%-10s${RESET} %-30s\n" "$jobid" "$state" "$short_name"
            shown=$(( shown + 1 ))
            (( shown >= 12 )) && break
        done <<< "$QUEUE_RAW"
    else
        # htcondor parsed format: "STATE|NAME|LOGPATH" (skipping the # summary line)
        printf "  %-10s %-30s\n" "STATE" "NAME"
        while IFS='|' read -r state name lg; do
            [[ "$state" == \#* || -z "$state" ]] && continue
            local color="$DIM"
            case "$state" in
                RUNNING) color="$BLUE"  ;;
                PENDING) color=""       ;;
                HELD)    color="$YELLOW";;
            esac
            local short_name="${name:0:30}"
            printf "  ${color}%-10s${RESET} %-30s\n" "$state" "$short_name"
            shown=$(( shown + 1 ))
            (( shown >= 12 )) && break
        done <<< "$QUEUE_RAW"
    fi

    if (( QUEUE_COUNT > 12 )); then
        echo "  ${DIM}… and $(( QUEUE_COUNT - 12 )) more${RESET}"
    fi
}

render_header() {
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${BOLD} km3tipi monitor${RESET}  ${DIM}— ${now}${RESET}"
    echo -e "  ${DIM}config:  ${CONFIG}${RESET}"
    echo -e "  ${DIM}results: ${RESULTS_DIR}${RESET}"
    echo
}

render_all() {
    render_header
    render_matrix
    echo
    render_queue
    if $WATCH; then
        echo
        echo -e "  ${DIM}refreshing every ${INTERVAL}s — Ctrl-C to exit${RESET}"
    fi
}

# --------------------------------------------------------------------------- #
# Main loop
# --------------------------------------------------------------------------- #

snapshot() {
    probe_filesystem
    probe_queue
    render_all
}

if $WATCH; then
    # Hide cursor, restore on exit (even on Ctrl-C).
    if $USE_COLOR; then
        printf '\033[?25l'
        trap 'printf "\033[?25h\n"; exit 0' INT TERM EXIT
    else
        trap 'echo; exit 0' INT TERM EXIT
    fi
    while true; do
        # Clear screen + home cursor each tick.
        $USE_COLOR && printf '\033[2J\033[H' || clear
        snapshot
        sleep "$INTERVAL"
    done
else
    snapshot
fi