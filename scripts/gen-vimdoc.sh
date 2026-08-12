#!/usr/bin/env bash
#
# Generate doc/bemtvi-dap.txt (the vimdoc help file) from doc/bemtvi-dap.md using
# panvimdoc <https://github.com/kdheepak/panvimdoc> (MIT, Dheepak Krishnamurthy).
# panvimdoc drives pandoc to do all the vimdoc column math — right-aligned *tags*,
# the table of contents, and tw=78 reflow — so the help file is never hand-aligned.
# Edit doc/bemtvi-dap.md, then run this.
#
# Requires: bash, git, pandoc (>= 3). panvimdoc is fetched on first run into a
# gitignored .panvimdoc/ cache, pinned to the SHA below.
set -euo pipefail

# --- per-plugin settings -----------------------------------------------------
PROJECT="bemtvi-dap"                                   # help-tag basename → :help bemtvi-dap
DESCRIPTION="A Debug Adapter Protocol client for bemtvi"  # header tagline (right side, line 1)
# -----------------------------------------------------------------------------

INPUT="doc/${PROJECT}.md"
OUTPUT="doc/${PROJECT}.txt"

# Pinned panvimdoc revision (bump deliberately to pick up upstream changes).
PANVIMDOC_REF="1f9433df889d4ab3daa5ea52c7069cb489ad47d6"

# Resolve repo root from this script's location so it runs from anywhere.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CACHE="$ROOT/.panvimdoc"

command -v pandoc >/dev/null 2>&1 || { echo "error: pandoc (>= 3) is required" >&2; exit 1; }

# Fetch/pin panvimdoc into the cache on first run.
if [ ! -e "$CACHE/panvimdoc.sh" ]; then
  echo "fetching panvimdoc @ ${PANVIMDOC_REF} into .panvimdoc/ ..."
  rm -rf "$CACHE"
  git clone --quiet https://github.com/kdheepak/panvimdoc.git "$CACHE"
  git -C "$CACHE" checkout --quiet "$PANVIMDOC_REF"
fi

echo "generating $OUTPUT from $INPUT ..."
bash "$CACHE/panvimdoc.sh" \
  --project-name "$PROJECT" \
  --input-file "$INPUT" \
  --vim-version "bemtvi" \
  --toc true \
  --description "$DESCRIPTION" \
  --title-date-pattern "%Y %B %d" \
  --dedup-subheadings true \
  --demojify true \
  --treesitter true

# panvimdoc runs pandoc's markdown reader, which curls straight quotes into
# typographic ones. Vim help convention is straight quotes, so normalize them
# back (code tokens are already left straight by pandoc, so this only touches
# prose). Em dash (—) and ellipsis (…) are intentional and left as-is.
sed -i "s/\xe2\x80\x99/'/g; s/\xe2\x80\x98/'/g; s/\xe2\x80\x9c/\"/g; s/\xe2\x80\x9d/\"/g" "$OUTPUT"

# panvimdoc's second header line is "For <version>    Last change: <date>". The
# date is non-deterministic (a freshness check would fail the next day) and the
# "For bemtvi" half just restates the description on line 1, so drop the line
# entirely — the output is then reproducible and doesn't say "bemtvi" twice.
sed -i '2d' "$OUTPUT"

# panvimdoc emits no blank line between the last table-of-contents entry and the
# first body line, so the TOC runs straight into the intro. Insert one blank line
# at that boundary (TOC entries end in "|link|"; the first body line does not).
awk '
  /^Table of Contents/ { seen = 1 }
  seen && !done && prev ~ /\|$/ && $0 !~ /\|$/ && $0 !~ /^[[:space:]]*$/ { print ""; done = 1 }
  { print; prev = $0 }
' "$OUTPUT" > "$OUTPUT.tmp" && mv "$OUTPUT.tmp" "$OUTPUT"

echo "done: $OUTPUT"
