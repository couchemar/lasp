#!/usr/bin/env bash
# Byte-diff the CLI output of two lasp binaries (stdout + exit code).
# Usage: tests/scripts/cli_diff.sh <old-binary> <new-binary> [inputs-list-file]
# Run from the repository root. Not part of `zig build test`.
#
# Every (input file x grammar) pair is run through `parse --jsonl`, plus raw
# tokens (no grammar), `query '*'`, `--names-only`, and `parse-dir` over
# tests/fixtures. One line is printed per differing invocation, then a count.
set -u

if [ $# -lt 2 ]; then
  echo "usage: $0 <old-binary> <new-binary> [inputs-list-file]" >&2
  exit 2
fi
OLD=$1
NEW=$2
LIST=${3:-/tmp/cli_inputs.txt}
: >"$LIST"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

total=0
diffs=0

# Progress goes to stderr every PROGRESS_EVERY cases so stdout (DIFF lines and
# the final count) stays unchanged. On a terminal the line is rewritten in
# place; otherwise one line per step is printed. PROGRESS_EVERY=0 disables it.
PROGRESS_EVERY=${PROGRESS_EVERY:-100}
progress() {
  [ "$PROGRESS_EVERY" -gt 0 ] || return 0
  if [ -t 2 ]; then
    printf '\r... %d cases, %d differing' "$total" "$diffs" >&2
  else
    printf '... %d cases, %d differing\n' "$total" "$diffs" >&2
  fi
}

# run_case <label> <args...>: runs both binaries with the same args.
run_case() {
  local label=$1
  shift
  total=$((total + 1))
  echo "$label" >>"$LIST"
  "$OLD" "$@" >"$tmp/old.out" 2>/dev/null </dev/null
  local oc=$?
  "$NEW" "$@" >"$tmp/new.out" 2>/dev/null </dev/null
  local nc=$?
  if [ $oc -ne $nc ] || ! cmp -s "$tmp/old.out" "$tmp/new.out"; then
    diffs=$((diffs + 1))
    # Clear an in-place progress line so the DIFF line starts at column 0.
    if [ "$PROGRESS_EVERY" -gt 0 ] && [ -t 2 ]; then printf '\r\033[K' >&2; fi
    echo "DIFF (exit $oc vs $nc): $label"
  fi
  if [ "$PROGRESS_EVERY" -gt 0 ] && [ $((total % PROGRESS_EVERY)) -eq 0 ]; then progress; fi
}

grammars=()
for g in examples/grammars/*.toml tests/fixtures/grammars/*.toml; do
  [ -f "$g" ] && grammars+=("$g")
done

inputs=()
for f in tests/fixtures/*.* tests/fixtures/dir_sample/* tests/fixtures/dir_txt_only/* \
  $(find src -name '*.zig' | sort) examples/grammars/*.toml README.md; do
  [ -f "$f" ] && inputs+=("$f")
done

for f in "${inputs[@]}"; do
  run_case "parse $f (no grammar)" parse "$f" --jsonl
  for g in "${grammars[@]}"; do
    run_case "parse $f -g $g" parse "$f" -g "$g" --jsonl
  done
done

# Query / names-only / alternatives over the main fixtures with the grammars.
for f in tests/fixtures/sample.zig tests/fixtures/sample.erl tests/fixtures/comments.erl \
  tests/fixtures/counts_sample.txt tests/fixtures/extent_brace_sample.txt \
  tests/fixtures/extent_terminator_sample.txt src/parser/tokenizer.zig src/main.zig; do
  [ -f "$f" ] || continue
  for g in "${grammars[@]}"; do
    run_case "query '*' $f -g $g" query '*' "$f" -g "$g" --jsonl
    run_case "parse --names-only $f -g $g" parse "$f" -g "$g" --names-only
    run_case "parse --alternatives $f -g $g" parse "$f" -g "$g" --alternatives --jsonl
  done
done

# Directory walk.
for g in tests/fixtures/grammars_dir tests/fixtures/grammars_multi_dir; do
  [ -d "$g" ] && run_case "parse-dir tests/fixtures --grammar-dir $g" parse-dir tests/fixtures --grammar-dir "$g" --jsonl
done

if [ "$PROGRESS_EVERY" -gt 0 ] && [ -t 2 ]; then printf '\n' >&2; fi
echo "cases: $total, differing: $diffs (inputs listed in $LIST)"
[ "$diffs" -eq 0 ]
