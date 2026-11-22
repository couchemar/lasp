#!/usr/bin/env bash
# Replay the error-invocation manifest against a lasp binary and compare with
# saved baselines (stdout, stderr, exit code per case).
#
# Usage: tests/scripts/error_prefix_diff.sh <binary> <outdir> [baseline-dir]
#   baseline-dir defaults to /tmp/before and must hold manifest.txt with
#   `name|cwd|args` lines (args are shell words; fixtures live at the cwds).
#   Results land in <outdir>/<name>.{stdout,stderr,exit}.
#
# Two comparisons are reported:
#   raw        byte-identical stdout, stderr and exit code
#   normalized a leading run of repeated `error: ` on each stderr line is
#              collapsed to one `error: ` first; stdout and exit stay exact
# Exit status is 0 only when the normalized comparison has no differences.
# Not part of `zig build test`.
set -u
if [ $# -lt 2 ]; then
  echo "usage: $0 <binary> <outdir> [baseline-dir]" >&2
  exit 2
fi
BIN=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
OUT=$2
BASE=${3:-/tmp/before}
MANIFEST=$BASE/manifest.txt
mkdir -p "$OUT"

# Collapse a leading run of `error: ` to one on every line.
normalize() {
  sed -E 's/^(error: )+/error: /' "$1"
}

raw_diffs=0
norm_diffs=0
total=0
while IFS='|' read -r name cwd args; do
  case "$name" in '' | '#'*) continue ;; esac
  total=$((total + 1))
  (
    cd "$cwd" || exit 99
    if [ "$name" = grammar_charset_stdin_dash ]; then
      echo a | eval "\"$BIN\" $args"
    else
      eval "\"$BIN\" $args" </dev/null
    fi
  ) >"$OUT/$name.stdout" 2>"$OUT/$name.stderr"
  echo $? >"$OUT/$name.exit"

  raw_same=1
  for ext in stdout stderr exit; do
    cmp -s "$BASE/$name.$ext" "$OUT/$name.$ext" || raw_same=0
  done
  if [ $raw_same -eq 0 ]; then
    raw_diffs=$((raw_diffs + 1))
    echo "RAW DIFF: $name"
  fi

  norm_same=1
  cmp -s "$BASE/$name.stdout" "$OUT/$name.stdout" || norm_same=0
  cmp -s "$BASE/$name.exit" "$OUT/$name.exit" || norm_same=0
  cmp -s <(normalize "$BASE/$name.stderr") <(normalize "$OUT/$name.stderr") || norm_same=0
  if [ $norm_same -eq 0 ]; then
    norm_diffs=$((norm_diffs + 1))
    echo "NORMALIZED DIFF: $name"
  fi
done <"$MANIFEST"

echo "cases: $total  raw differences: $raw_diffs  normalized differences: $norm_diffs"
[ $norm_diffs -eq 0 ]
