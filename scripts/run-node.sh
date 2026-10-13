#!/bin/zsh
set -euo pipefail
# Legacy command-path adapter. No Node process is started.
ROOT="${0:A:h:h}"
if [[ "${1:t}" != "oos-state.js" ]]; then
  print -u2 'The Node runtime has been removed. Use scripts/oos-state.'
  exit 64
fi
shift
exec "$ROOT/scripts/oos-state" "$@"
