#!/usr/bin/env bash
#
# Verify doc/bemtvi-dap.txt is up to date with the Markdown it is generated
# from. Regenerates it and fails if the result differs from what is committed — so a
# push can't ship a help file that no longer matches doc/bemtvi-dap.md. Wired
# as a pre-push hook via pre-commit (see .pre-commit-config.yaml); run it directly any
# time to check.
#
# The generator is deliberately reproducible (gen-vimdoc.sh strips panvimdoc's
# changing date line and normalizes smart quotes), so regenerating on a different day
# produces a byte-identical file and this check is meaningful.
#
# Requires: bash, git, pandoc (>= 3). panvimdoc is fetched into a gitignored cache on
# first run.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUTPUT="doc/bemtvi-dap.txt" # must match OUTPUT in gen-vimdoc.sh

command -v pandoc >/dev/null 2>&1 || {
  echo "error: pandoc (>= 3) is required to verify the vimdoc" >&2
  exit 1
}

bash scripts/gen-vimdoc.sh >/dev/null

if ! git diff --quiet -- "$OUTPUT"; then
  {
    echo "error: $OUTPUT is out of date — regenerate and commit it:"
    echo "  bash scripts/gen-vimdoc.sh"
  } >&2
  exit 1
fi

echo "vimdoc up to date"
