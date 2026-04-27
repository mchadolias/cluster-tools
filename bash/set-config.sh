set-config#!/usr/bin/env bash

# Exit on error
set -e

# Check arguments
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <key> <value> [--global|--local|--system]"
    echo "Example:"
    echo "  $0 user.name 'Michalis Chadolias' --global"
    exit 1
fi

KEY="$1"
VALUE="$2"
SCOPE="${3:---global}"  # Default to --global

# Validate scope
if [[ "$SCOPE" != "--global" && "$SCOPE" != "--local" && "$SCOPE" != "--system" ]]; then
    echo "Invalid scope. Use --global, --local, or --system."
    exit 1
fi

echo "Setting $KEY to '$VALUE' ($SCOPE)"

git config $SCOPE "$KEY" "$VALUE"

echo "Done."
