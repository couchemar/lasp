# AGENTS.md

Guidance for AI coding agents working in this repository. This project uses **LASP**, a language-agnostic structural code parser, via a globally installed `lasp` binary.

> This file is a template. Copy it into a project as `AGENTS.md` (or merge it into an existing one). It assumes `lasp` is on your `$PATH` and that project-specific grammars and feedback live under `.lasp/` in the project root.

## What LASP is

LASP is "jq for code structure." Given a source file and a TOML grammar, it detects structural constructs (functions, calls, classes, imports, blocks) and emits them as JSON events or filtered query results. It does **not** build a full AST — just the structural skeleton. Grammars are plain TOML, so you can describe any language or DSL without recompiling anything.

Use it to map a file's structure before editing, locate definitions and call sites, count constructs, and build refactor safety nets — faster and more precise than reading whole files or using naive `grep`.

## Prerequisites

- `lasp` installed globally and on `$PATH`. Verify:
  ```bash
  lasp --version
  ```
- If the command is not found, install LASP and re-run the check before relying on it.

## Project layout for LASP

Store everything LASP-related under a `.lasp/` directory at the **project root**:

```
<project-root>/
 ├─ .lasp/
 │   ├─ grammars/     # TOML grammar files, one per language (e.g. python.toml, erlang.toml)
 │   └─ feedbacks/    # dated evaluation reports when LASP mis-parses something
 └─ ...
```

- **Grammars**: `.lasp/grammars/<language>.toml`. Author or refine these as you encounter new languages or DSLs in the project.
- **Feedback**: `.lasp/feedbacks/<YYYY-MM-DD>.md`. Record false positives, false negatives, wrong token kinds, or missing features so the grammar (or LASP itself) can be improved.

Create the directories if they do not exist:

```bash
mkdir -p .lasp/grammars .lasp/feedbacks
```

## Dogfood rule: use LASP before reading files

**Prefer LASP over reading a whole file or grepping when you need structure.**

**Map a file's structure before editing it:**
```bash
lasp parse src/app.py -g .lasp/grammars/python.toml --node function --names-only
```

**Find a definition (wildcard matches any node type):**
```bash
lasp query '*[name="handle_request"]' src/app.py -g .lasp/grammars/python.toml --names-only
```

**Find all call sites of a function:**
```bash
lasp query 'call[callee="validate"]' src/app.py -g .lasp/grammars/python.toml --names-only
```

**Refactor safety net — diff structure before/after a change:**
```bash
lasp parse src/app.py -g .lasp/grammars/python.toml --node function --names-only > /tmp/before.txt
# ... make edits ...
diff /tmp/before.txt <(lasp parse src/app.py -g .lasp/grammars/python.toml --node function --names-only)
```

**Count constructs:**
```bash
lasp parse src/app.py -g .lasp/grammars/python.toml --node function --names-only | wc -l
```

**Pipe source from stdin** (no file on disk):
```bash
cat src/app.py | lasp parse - -g .lasp/grammars/python.toml --node function --names-only
```

Read the raw source only when you need the actual code text (to edit it, or to read a body LASP intentionally doesn't descend into).

## Commands

### Raw tokens (no grammar) — explore an unknown file
```bash
lasp parse <file>
```
Emits every token with kind and byte offsets. Use this to discover the token patterns that mark structural constructs before writing a grammar.

### Structural parse (with grammar)
```bash
lasp parse <file> -g .lasp/grammars/<lang>.toml
lasp parse <file> --grammar .lasp/grammars/<lang>.toml   # long form
```

### Filters and output modes
```bash
lasp parse <file> -g .lasp/grammars/<lang>.toml --node function   # only events of one type (case-insensitive)
lasp parse <file> -g .lasp/grammars/<lang>.toml --names-only      # first capture value per event, one per line
```
`--node` and `--names-only` compose, and both are silently ignored when no grammar is given (raw tokens are emitted instead).

### Structural query (CSS-selector-inspired)
```bash
lasp query 'function' <file> -g .lasp/grammars/<lang>.toml
lasp query 'function[name="foo"]' <file> -g .lasp/grammars/<lang>.toml
lasp query 'call[callee!="print"]' <file> -g .lasp/grammars/<lang>.toml
lasp query '*[confidence>0.8]' <file> -g .lasp/grammars/<lang>.toml
```
`query` always requires a grammar and supports `--names-only` and stdin (`-`).

| Selector | Meaning |
|----------|---------|
| `function` | Events of type "function" (case-insensitive) |
| `*` | All events (wildcard) |
| `function[name="foo"]` | type is function and captured `name` equals `foo` |
| `call[callee!="print"]` | `callee` is absent or not equal to `print` |
| `*[confidence>0.7]` | confidence strictly above 0.7 |
| `function[name="foo"][confidence>0.8]` | multiple conditions, AND-combined |

### Stdin
Use `-` as the file path to read source from stdin:
```bash
echo 'def add(a, b): return a + b' | lasp parse - -g .lasp/grammars/python.toml
```

### Version
```bash
lasp --version   # also: lasp -V  or  lasp version
```

## Writing a grammar

Grammars are TOML files in `.lasp/grammars/`. No recompilation is needed — edit and re-run.

```toml
[language]
name = "python"

[keywords]
function = ["def", "async"]
class = ["class"]
import = ["import", "from"]

[[patterns]]
type = "function"
sequence = ["def", "$name:IDENTIFIER", "("]

[[patterns]]
type = "class"
sequence = ["class", "$name:IDENTIFIER"]

[[patterns]]
type = "call"
sequence = ["$callee:IDENTIFIER", "("]

[blocks]
open = "{"
close = "}"
```

### Sequence elements

| Element | Matches |
|---------|---------|
| `"fn"` | Exact keyword text (also matches identifiers with reduced confidence) |
| `"("` | Exact symbol/delimiter |
| `"identifier"` | Any identifier token |
| `"$name:IDENTIFIER"` | Identifier, captured into the `name` field |
| `"Config:IDENTIFIER"` | Identifier with exact text `Config` (no capture) |
| `"fn?"` / `"(?"` | Optional element — boosts confidence when present, doesn't block when absent |

### Position constraint
Restrict a pattern to column 0 (line start):
```toml
[[patterns]]
type = "function"
sequence = ["$name:IDENTIFIER", "("]
position = "start"
```

### Pattern constraints (filter false positives)
Use `[[patterns.constraints]]` with a `depth` that selects what to check:

| depth | Checks | Use for |
|-------|--------|---------|
| 0 | the captured field value | excluding known built-ins (`print`, `len`) |
| 1 | the immediately preceding token | excluding `fun(`, `= foo(` |
| 2..N | the last N tokens (lookback window) | excluding `-spec foo(`, `-type bar(` |

```toml
[[patterns]]
type = "function"
sequence = ["$name:IDENTIFIER", "("]
position = "start"

[[patterns.constraints]]
type = "not"
depth = 1
values = ["fun", "="]

[[patterns.constraints]]
type = "not"
depth = 0
field = "name"
values = ["print", "len"]
```
Constraints are evaluated in order and short-circuit on the first rejection. `field` is required when `depth = 0` and forbidden otherwise.

### Comment prefixes
If the language's comments are not C-style (`//`, `#`, `/* */`), declare them so comment lines don't become token noise:
```toml
[comments]
line = ["%"]            # e.g. Erlang; use ["--"] for Lua/SQL/Haskell
block_open = "{-"
block_close = "-}"
```

### Configurable confidence weights (optional)
```toml
[weights]
keyword = 0.6
identifier = 0.2
symbol = 0.15
block = 0.3
relaxed_keyword = 0.1
```

### Grammar authoring tips
1. Keep patterns short — `"fn" IDENTIFIER "("` is ideal; don't try to match full argument lists.
2. Start patterns with a distinct keyword (`fn`, `class`, `import`) to avoid ambiguity.
3. Avoid `IDENTIFIER IDENTIFIER` sequences — they match too many unstructured contexts.
4. Focus on structural nodes: functions, classes, imports, calls, blocks. Skip expressions.
5. Use constraints and `position` to cut false positives instead of making patterns longer.

## Workflow: analyze an unfamiliar file

1. `lasp parse <file>` (no grammar) to see the raw token stream.
2. Identify the keyword/symbol patterns that mark the constructs you care about.
3. Write `.lasp/grammars/<lang>.toml` with those patterns.
4. `lasp parse <file> -g .lasp/grammars/<lang>.toml` and check the output.
5. Iterate: add captures, `position`, and constraints to remove false positives.
6. If LASP misbehaves in a way the grammar can't fix, record it under `.lasp/feedbacks/` (see below).

## Output fields

**Token events (no grammar):** `type` (identifier, keyword, symbol, string, number, operator, newline, indent, comment, delimiter), `start`, `end` (byte offsets), `line` (1-based), `col` (0-based).

**Structural events (with grammar):** `type`, `start`, `end`, `line`, `col`, `confidence` (0.0–1.0), optional `block_start`, and captured fields such as `name` / `callee`.

### Confidence
| Score | Meaning |
|-------|---------|
| 1.0 | All elements matched with expected token kinds |
| 0.7–0.9 | Strong — relaxed keyword match or an optional element absent |
| 0.5–0.7 | Plausible — partial structure |
| 0.3–0.5 | Weak |
| < 0.3 | Filtered out (not emitted) |

Use `[confidence>0.8]` in queries to separate solid matches from relaxed guesses.

## Recording feedback

When LASP mis-parses something the grammar cannot reasonably fix, append to a dated report in `.lasp/feedbacks/<YYYY-MM-DD>.md`. Capture:

- **Type**: false-positive | false-negative | wrong-token | missing-feature
- **File** and line, and the **grammar** used (path under `.lasp/grammars/`)
- **What happened vs. what should happen** — include the offending event JSON or the raw token stream around the location (`lasp parse <file>` with no grammar)
- A minimal repro if you can isolate one

Example entry:
```markdown
## Function heads missed after a comment with an apostrophe

**Type:** false-negative
**Date:** 2026-08-30
**File:** src/mod.erl:40
**Grammar:** .lasp/grammars/erlang.toml
**Details:** `lasp parse src/mod.erl -g .lasp/grammars/erlang.toml --node function`
returned 2 of 22 heads. Header comment contains an apostrophe; without a
configured `%` line-comment prefix the apostrophe opened a spurious string that
swallowed later code. Fix: add `[comments]` with `line = ["%"]` to the grammar.
```

## Where LASP helps vs. where it doesn't

- **Use LASP for:** structural overviews, locating definitions and call sites, counting constructs, cross-file reference maps, and refactor diffs. Its call-site counts are more precise than naive `grep` because it understands token structure.
- **Use grep + read for:** exact-text search with surrounding context, and reading bodies to edit them. LASP is a structural-overview tool, not an editor — the two are complementary.
