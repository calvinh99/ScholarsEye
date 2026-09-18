#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
exec /usr/bin/python3 "$PROJECT_ROOT/scripts/update_release.py" "$@"
