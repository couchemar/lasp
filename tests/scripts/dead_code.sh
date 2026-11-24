#!/usr/bin/env bash
# LASP dead-code report: uses LASP on its own src/ to list functions nothing
# references.
# Usage: tests/scripts/dead_code.sh [LASP_BINARY]   (default .bin/lasp)
# Run from the repository root. Not part of `zig build test`.
#
# Section 1 "Unreferenced functions": no mention outside the definition and no
#   mention in tests. Exit 1 when non-empty.
# Section 2 "Test-only functions": mentioned only inside test blocks (info).
# Exit codes: 0 section 1 empty, 1 section 1 non-empty,
#             2 usage/tool failure (binary missing/not executable, lasp failed).
#
# The analysis is name-based. Limits: it cannot see same-name collisions,
# write-only locals, test-only fields, transitively dead types, discarded
# parameters, or duplicate shapes.
set -u

# --- All Zig-specific knowledge lives here ---------------------------------
LASP="${1:-.bin/lasp}"
ZIG_GRAMMAR="examples/grammars/zig.toml"
TEST_BLOCK_GRAMMAR="tests/fixtures/grammars/zig_test_blocks.toml"
SCAN_GLOB="src/**/*.zig"
DEFINITION_TYPES="function pub_function"
# Names exempt from failing section 1. One reason per entry.
#   main: program entry point, referenced by the Zig runtime, not by name.
ALLOWLIST="main"
# ---------------------------------------------------------------------------

if [ ! -f "$LASP" ] || [ ! -x "$LASP" ]; then
  echo "error: LASP binary not found or not executable: $LASP" >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found on PATH" >&2; exit 2; }

export ZIG_GRAMMAR TEST_BLOCK_GRAMMAR SCAN_GLOB DEFINITION_TYPES ALLOWLIST
exec python3 - "$LASP" <<'PY'
import glob, json, os, subprocess, sys
from bisect import bisect_right
from collections import defaultdict

lasp = sys.argv[1]
zig_grammar = os.environ["ZIG_GRAMMAR"]
test_grammar = os.environ["TEST_BLOCK_GRAMMAR"]
scan_glob = os.environ["SCAN_GLOB"]
def_types = set(os.environ["DEFINITION_TYPES"].split())
allowlist = set(os.environ["ALLOWLIST"].split())

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
    out = []
    for line in p.stdout.decode("utf-8", "replace").splitlines():
        if line.strip():
            out.append(json.loads(line))
    return out

files = sorted(glob.glob(scan_glob, recursive=True))
if not files:
    print("error: no files match %s" % scan_glob, file=sys.stderr)
    sys.exit(2)

prod_defs = defaultdict(list)
mentions_prod = defaultdict(int)
mentions_test = defaultdict(int)

for f in files:
    with open(f, "rb") as fh:
        src = fh.read()
    regions = sorted((e["start"], e["body_end"]) for e in run(["parse", f, "-g", test_grammar, "--jsonl"]) if "body_end" in e)
    starts = [r[0] for r in regions]
    ends = [r[1] for r in regions]
    def in_test(pos):
        i = bisect_right(starts, pos) - 1
        return i >= 0 and pos < ends[i]
    for e in run(["parse", f, "-g", zig_grammar, "--jsonl"]):
        if e.get("type") in def_types and "name" in e and not in_test(e["start"]):
            prod_defs[e["name"]].append((f, e["line"]))
    for t in run(["parse", f, "--jsonl"]):
        if t.get("type") != "identifier":
            continue
        name = src[t["start"]:t["end"]].decode("utf-8", "replace")
        if in_test(t["start"]):
            mentions_test[name] += 1
        else:
            mentions_prod[name] += 1

sec1, sec2 = [], []
for name, defs in prod_defs.items():
    prod_refs = mentions_prod[name] - len(defs)
    test_refs = mentions_test[name]
    if prod_refs > 0:
        continue
    if test_refs == 0:
        if name not in allowlist:
            sec1.extend((name, f, l) for f, l in defs)
    else:
        sec2.extend((name, f, l) for f, l in defs)

print("LASP dead-code report (binary: %s)" % lasp)
print("note: name-based; cannot see same-name collisions, write-only locals, test-only fields, transitively dead types, discarded parameters, or duplicate shapes")
print("== Unreferenced functions ==")
for n, f, l in sorted(sec1):
    print("%s %s:%d" % (n, f, l))
print("== Test-only functions ==")
for n, f, l in sorted(sec2):
    print("%s %s:%d" % (n, f, l))
sys.exit(1 if sec1 else 0)
PY
