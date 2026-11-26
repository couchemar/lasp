#!/usr/bin/env bash
# LASP union-read check: lists direct toml.Value union reads (`base.field` with
# field in string/array/integer/float/bool/table) outside test blocks.
# Usage: tests/scripts/union_reads.sh [LASP_BINARY] [FILE...]
#   defaults: .bin/lasp  src/grammar/loader.zig
# Run from the repository root. Not part of `zig build test`.
# Output: one `file:line base.field` per hit.
# Exit codes: 0 no hits, 1 any hit, 2 usage/tool failure.
# Limits: see the header of tests/fixtures/grammars/zig_union_reads.toml.
set -u
LASP="${1:-.bin/lasp}"
[ $# -gt 0 ] && shift
[ $# -eq 0 ] && set -- src/grammar/loader.zig
# --- All Zig-specific knowledge lives here ---------------------------------
UNION_GRAMMAR="tests/fixtures/grammars/zig_union_reads.toml"
TEST_BLOCK_GRAMMAR="tests/fixtures/grammars/zig_test_blocks.toml"
UNION_FIELDS="string array integer float bool table"
# ---------------------------------------------------------------------------
if [ ! -f "$LASP" ] || [ ! -x "$LASP" ]; then
  echo "error: LASP binary not found or not executable: $LASP" >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found on PATH" >&2; exit 2; }
export UNION_GRAMMAR TEST_BLOCK_GRAMMAR UNION_FIELDS
exec python3 - "$LASP" "$@" <<'PY'
import json, os, subprocess, sys
from bisect import bisect_right
lasp = sys.argv[1]
files = sys.argv[2:]
fields = set(os.environ["UNION_FIELDS"].split())
def run(args):
    cmd = [lasp] + args
    try:
        p = subprocess.run(cmd, capture_output=True)
    except OSError as e:
        print("error: failed to run: %s (%s)" % (" ".join(cmd), e), file=sys.stderr)
        sys.exit(2)
    if p.returncode != 0:
        print("error: command failed (exit %d): %s" % (p.returncode, " ".join(cmd)), file=sys.stderr)
        sys.exit(2)
    return [json.loads(l) for l in p.stdout.decode("utf-8", "replace").splitlines() if l.strip()]
hits = []
for f in files:
    regions = sorted((e["start"], e["body_end"]) for e in run(["parse", f, "-g", os.environ["TEST_BLOCK_GRAMMAR"], "--jsonl"]) if "body_end" in e)
    starts = [r[0] for r in regions]
    ends = [r[1] for r in regions]
    def in_test(pos):
        i = bisect_right(starts, pos) - 1
        return i >= 0 and pos < ends[i]
    for e in run(["parse", f, "-g", os.environ["UNION_GRAMMAR"], "--jsonl"]):
        if e.get("type") == "union_read" and e.get("field") in fields and not in_test(e["start"]):
            hits.append((f, e["line"], e.get("base", "*"), e["field"]))
for f, l, b, fld in hits:
    print("%s:%d %s.%s" % (f, l, b, fld))
sys.exit(1 if hits else 0)
PY
