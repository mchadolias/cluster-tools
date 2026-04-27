#!/usr/bin/env bash
# ============================================================================
# export_conda.sh — export a conda environment to environment.yml, cleanly.
#
# Compared to a raw `conda env export`, this:
#   - drops the absolute `prefix:` line (so the file is portable)
#   - uses --from-history for conda deps (only what you asked for, not the
#     full transitive closure)
#   - re-attaches the pip section from a full export so pip-only deps
#     aren't lost
#   - optionally excludes a specific package from the pip section
#     (useful for editable-installed local libraries)
# ============================================================================
set -euo pipefail

ENV_NAME=""
OUTPUT_FILE="environment.yml"
EXCLUDE_MODULE=""

usage() {
	cat <<EOF
Usage: $(basename "$0") [-n env_name] [-o output_file] [-x exclude_module]

  -n  Name of the conda environment (default: currently active env)
  -o  Output filename (default: environment.yml)
  -x  Module name to exclude from the pip section
      (e.g. an editable-installed local library)
  -h  Show this help

Examples:
  $(basename "$0") -n analysis -o analysis.yml
  $(basename "$0") -n myenv -x mylocallib
EOF
}

while getopts "n:o:x:h" opt; do
	case "$opt" in
		n) ENV_NAME="$OPTARG" ;;
		o) OUTPUT_FILE="$OPTARG" ;;
		x) EXCLUDE_MODULE="$OPTARG" ;;
		h) usage; exit 0 ;;
		*) usage; exit 1 ;;
	esac
done

# Default to the active env if -n not given
if [[ -z "$ENV_NAME" ]]; then
	ENV_NAME="${CONDA_DEFAULT_ENV:-}"
fi

if [[ -z "$ENV_NAME" || "$ENV_NAME" == "base" ]]; then
	echo "Error: no environment specified and no non-base env active." >&2
	echo "       Use -n <name> or activate an env first." >&2
	exit 1
fi

command -v conda >/dev/null 2>&1 || { echo "conda not in PATH" >&2; exit 1; }

echo "Exporting environment: $ENV_NAME"

TMP_FULL=$(mktemp)
trap 'rm -f "$TMP_FULL"' EXIT

# 1. History-based export (just the deps the user asked for) without prefix
conda env export -n "$ENV_NAME" --from-history | grep -v '^prefix: ' > "$OUTPUT_FILE"

# 2. Full export to harvest the pip section
conda env export -n "$ENV_NAME" > "$TMP_FULL"

# 3. Extract pip block (everything from "- pip:" to end), drop prefix line
PIP_BLOCK=$(sed -n '/^[[:space:]]*-[[:space:]]*pip:/,$p' "$TMP_FULL" | grep -v '^prefix: ' || true)

# 4. Optionally exclude a module from the pip block
if [[ -n "$EXCLUDE_MODULE" && -n "$PIP_BLOCK" ]]; then
	PIP_BLOCK=$(printf '%s\n' "$PIP_BLOCK" | grep -v -E "(^|/)${EXCLUDE_MODULE}(==|$|[[:space:]])" || true)
fi

# 5. Append pip block if non-empty
if [[ -n "$PIP_BLOCK" ]]; then
	printf '%s\n' "$PIP_BLOCK" >> "$OUTPUT_FILE"
fi

echo "Wrote: $OUTPUT_FILE${EXCLUDE_MODULE:+  (excluded: $EXCLUDE_MODULE)}"
