# LASP Usage Guide for Coding Agents

## What LASP Does

LASP is a language-agnostic structural parser. Given source code and a TOML grammar file, it detects structural constructs (functions, calls, structs, imports) and outputs them as JSON. No full AST — just the structural skeleton.

## Binary

The LASP binary is located at `.bin/lasp`. It is a standalone CLI tool with no runtime dependencies.

## Commands

### Raw token output (no grammar)

```bash
.bin/lasp parse <file>
```

Returns every token with type, byte offsets, line number, and column:

```json
{ "events": [
  { "type": "keyword", "start": 0, "end": 2, "line": 1, "col": 0 },
  { "type": "identifier", "start": 3, "end": 6, "line": 1, "col": 3 }
] }
```

Use this to explore a file's token structure before writing a grammar.

### Stdin pipe support

Use `"-"` as the file path to read source from stdin instead of a file:

```bash
echo 'fn add(a: i32, b: i32) i32 { return a + b; }' | .bin/lasp parse -
echo 'fn add(a: i32, b: i32) i32 { return a + b; }' | .bin/lasp parse - -g examples/grammars/zig.toml
cat src/main.zig | .bin/lasp parse - -g examples/grammars/zig.toml
```

When `"-"` is the target path, LASP reads all bytes from stdin until EOF and processes them identically to file input. Empty stdin produces an empty events array.

### Structural parsing (with grammar)

```bash
.bin/lasp parse <file> --grammar <grammar.toml>
# or short form:
.bin/lasp parse <file> -g <grammar.toml>
```

Returns structural events with captures, confidence scores, and position info:

```json
{ "events": [
  { "type": "function", "start": 0, "end": 15, "line": 1, "confidence": 1.00, "col": 0, "name": "add" }
] }
```

### Node type filtering (`--node` / `-n`)

Emit only structural events matching a specific type name:

```bash
.bin/lasp parse file.zig -g examples/grammars/zig.toml --node function
.bin/lasp parse file.zig -g examples/grammars/zig.toml -n call
```

The comparison is case-insensitive. When the filter matches zero events, the output is a valid JSON object with an empty events array. When no grammar is specified, `--node` is silently ignored and raw token JSON is emitted.

### Names-only output (`--names-only`)

Emit just the first capture value per event, one per line — plain text, no JSON:

```bash
.bin/lasp parse file.zig -g examples/grammars/zig.toml --names-only
```

Output:

```
add
subtract
multiply
```

Events with no captures are skipped. When no grammar is specified, `--names-only` is silently ignored and raw token JSON is emitted.

### Composable pipelines

All three features compose together. Combine stdin, node filtering, and names-only output for powerful one-liners:

```bash
# Pipe source, filter to functions, get just names
echo 'fn add() void {} fn sub() void {}' | .bin/lasp parse - -g examples/grammars/zig.toml --node function --names-only

# List all function names in a file
.bin/lasp parse src/main.zig -g examples/grammars/zig.toml --node function --names-only

# Pipe source and filter to calls, JSON output
cat src/main.zig | .bin/lasp parse - -g examples/grammars/zig.toml --node call# Count functions in a file
.bin/lasp parse src/main.zig -g examples/grammars/zig.toml --node function --names-only | wc -l

# Find a specific function
.bin/lasp parse src/main.zig -g examples/grammars/zig.toml --node function --names-only | grep parseArgs

# Diff function lists between files
diff <(.bin/lasp parse a.zig -g examples/grammars/zig.toml --node function --names-only) \
     <(.bin/lasp parse b.zig -g examples/grammars/zig.toml --node function --names-only)
```

### Version

```bash
.bin/lasp --version   # same as: .bin/lasp -V  or: .bin/lasp version
```

Output:

```
lasp 0.2.0
```

The version is embedded at build time from `build.zig.zon` (semver). To release a new version: bump `version` in `build.zig.zon` and add a `CHANGELOG.md` entry (Keep a Changelog format). `--version`/`-V` is also accepted among other flags and exits before reading any file.

### Help

LASP provides built-in help for discoverability:

```bash
.bin/lasp help          # General usage help
.bin/lasp --help        # Same as help
.bin/lasp -h            # Same as help
.bin/lasp parse --help  # Help for parse subcommand
.bin/lasp query --help  # Help for query subcommand
```

Help takes precedence over other flags: `.bin/lasp --help --version` shows help, not version. When no arguments are given (`.bin/lasp`), general help is printed to stderr with a non-zero exit code.

## Structural Query (`lasp query`)

Query events using CSS-selector-inspired syntax. Requires a grammar (`-g`).

### Syntax

```
lasp query '<selector>' <file> -g <grammar.toml> [--names-only]
```

### Selector syntax

| Selector | Meaning |
|----------|---------|
| `function` | Events with type "function" (case-insensitive) |
| `*` | All events (wildcard) |
| `function[name="foo"]` | Functions where captured `name` equals "foo" |
| `function[name!="print"]` | Functions where `name` is NOT "print" (or field absent) |
| `call[confidence>0.7]` | Calls with confidence above 0.7 |
| `*[confidence>0.9]` | All events with high confidence |
| `function[name="foo"][confidence>0.8]` | Multiple conditions (AND) |

### Examples

```bash
# Find all functions
.bin/lasp query 'function' file.zig -g examples/grammars/zig.toml

# Find a specific function by name
.bin/lasp query 'function[name="add"]' file.zig -g examples/grammars/zig.toml

# Find high-confidence events
.bin/lasp query '*[confidence>0.8]' file.zig -g examples/grammars/zig.toml

# Exclude known built-in calls
.bin/lasp query 'call[name!="print"]' file.dart -g grammars/dart.toml

# Names-only output for scripting
.bin/lasp query 'function' file.zig -g examples/grammars/zig.toml --names-only

# Pipe source via stdin
echo 'fn add() void {}' | .bin/lasp query 'function' - -g examples/grammars/zig.toml

# Combined: stdin + query + names-only
cat src/main.zig | .bin/lasp query 'function[name!="main"]' - -g examples/grammars/zig.toml --names-only
```

### Attribute conditions

- `[field="value"]` — equality: include events where capture `field` equals `value`
- `[field!="value"]` — negation: include events where `field` is absent or differs from `value`
- `[confidence>N]` — threshold: include events with confidence strictly above N (0.0–1.0)
- Multiple conditions are AND-combined: all must pass

### Differences from `--node`

`--node` is a simple type filter on `lasp parse`. `lasp query` is more expressive:
- Attribute conditions (`[name="foo"]`, `[confidence>0.7]`)
- Negation (`[name!="print"]`)
- Wildcard type (`*`)
- Grammar is always required (no raw token mode)

## Writing a Grammar

Grammars are TOML files. You can write one for any language without recompiling LASP.

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

### Same-type pattern union

Multiple `[[patterns]]` entries that share the same `type` name are **alternatives of one type**: an occurrence matching any of them emits a single event of that shared type. This lets you describe one logical construct in several shapes:

```toml
[[patterns]]
type = "reference"
sequence = ["&", "$callee:IDENTIFIER"]          # bare capture ref  &foo

[[patterns]]
type = "reference"
sequence = ["&", "$callee:IDENTIFIER", "/", "number"]  # arity-qualified  &foo/1
```

Semantics:
- **Non-overlapping alternatives** each emit their own event (both forms above are detected).
- **Overlapping alternatives** collapse to one primary event per construct: highest confidence → longest match → grammar order. If one alternative's sequence is a prefix of another's and the source matches the longer form, the longer form wins — the shorter is never emitted separately from the same start.
- **Equivalent choice**: a `Type_Union` of alternatives and a single optional-tail pattern (`["&", "$callee:IDENTIFIER", "/?", "number?"]`) produce the same type, captures, and source region. Pick whichever reads more clearly.
- Failing alternatives are never exposed without `--alternatives` (a separate feature); by default only the winner is emitted.
- Works for any `type` name — the engine hardcodes none, and no new flags or grammar keys are needed.

### Position constraints

Restrict a pattern to match only at column 0 (line start):

```toml
[[patterns]]
type = "function"
sequence = ["$name:IDENTIFIER", "("]
position = "start"
```

### Pattern constraints

Constraints filter matches after the structural pattern matches. They use a unified `[[patterns.constraints]]` system with a `depth` parameter that determines what gets checked.

#### Capture value filtering (depth=0)

Reject matches where a captured field value is in a blacklist. Requires a `field` key specifying which capture to check:

```toml
[[patterns]]
type = "method"
sequence = ["$name:IDENTIFIER", "("]

[[patterns.constraints]]
type = "not"
depth = 0
field = "name"
values = ["print", "RegExp", "Future", "Timer"]
```

#### Preceding token check (depth=1)

Reject matches where the immediately preceding non-skip token matches:

```toml
[[patterns]]
type = "function"
sequence = ["$name:IDENTIFIER", "("]
position = "start"

[[patterns.constraints]]
type = "not"
depth = 1
values = ["fun", "="]
```

#### Lookback window check (depth=2..N)

Reject matches where any of the last N non-skip tokens matches. The window size is configurable via the `depth` value:

```toml
[[patterns]]
type = "function"
sequence = ["$name:IDENTIFIER", "("]
position = "start"

[[patterns.constraints]]
type = "not"
depth = 4
values = ["-spec", "-type"]
```

Multiple constraints can be combined on one pattern. They are evaluated in order after the position check, with short-circuit on first rejection.

```toml
[[patterns]]
type = "function"
sequence = ["$name:IDENTIFIER", "("]
position = "start"

[[patterns.constraints]]
type = "not"
depth = 4
values = ["-spec", "-type"]

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

### Optional elements

Mark sequence elements as optional with `?` — they boost confidence when present but don't prevent matching when absent:

```toml
[[patterns]]
type = "function"
sequence = ["fn", "$name:IDENTIFIER", "(?"]
```

When `(` is present: confidence = 1.0. When absent: confidence < 1.0 but the event is still emitted.

### Configurable weights

Override default evidence weights per language:

```toml
[weights]
keyword = 0.6
identifier = 0.2
symbol = 0.15
block = 0.3
relaxed_keyword = 0.1
```

Omitted keys use defaults. Negative values are rejected.

### Comment syntax

Declare the language's comment prefixes so the tokenizer recognizes comments at runtime. Omit the section for default C-style comments (`//`, `#`, `/* */`):

```toml
[comments]
line = ["%"]              # Erlang: % line comments
```

```toml
[comments]
line = ["--"]             # Lua / SQL
block_open = "{-"         # Haskell block comments
block_close = "-}"
```

- `line`: up to 16 prefixes, each 1–8 chars; a line comment runs to end-of-line.
- `block_open`/`block_close`: 1–8 chars, must be supplied together (one alone is an error); unclosed block comments extend to EOF.
- Longest match wins for overlapping prefixes (`-` vs `--`).
- Declaring the right prefix (e.g. Erlang `%`) fixes the apostrophe-in-comment bug — a `'` inside a comment no longer opens a spurious string that swallows later code.

### Sequence elements

| Element | Matches |
|---------|---------|
| `"fn"` | Exact keyword text (also matches identifiers with reduced confidence) |
| `"("` | Exact symbol/delimiter |
| `"identifier"` | Any identifier token |
| `"$name:IDENTIFIER"` | Identifier, captured into `name` field |
| `"Config:IDENTIFIER"` | Identifier with exact text `Config` (no capture) |
| `"fn?"` | Optional keyword — boosts confidence when present |
| `"(?"` | Optional symbol — boosts confidence when present |
| Same `type` on multiple `[[patterns]]` | Alternatives of one type; overlap collapses to longest match → grammar order |

## Workflow: Analyze an Unfamiliar Codebase

1. Run `.bin/lasp parse <file>` without a grammar to see raw tokens
2. Identify keyword/symbol patterns that mark structural constructs
3. Write a `.toml` grammar with those patterns
4. Run `.bin/lasp parse <file> -g <grammar.toml>` and check the output
5. Iterate: adjust patterns, add captures, tune position/constraint rules

## Output Fields

### Token events (no grammar)

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | Token kind: identifier, keyword, symbol, string, number, operator, newline, indent, comment, delimiter |
| `start` | int | Byte offset of token start |
| `end` | int | Byte offset of token end |
| `line` | int | 1-based line number |
| `col` | int | 0-based byte column from line start |

### Structural events (with grammar)

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | Pattern type name (e.g. "function", "call") |
| `start` | int | Byte offset of match start |
| `end` | int | Byte offset of match end |
| `line` | int | 1-based line number |
| `col` | int | 0-based column of first matched token |
| `confidence` | float | Match confidence 0.0–1.0 |
| `block_start` | int? | Byte offset of enclosing block open delimiter (only when inside a block) |
| `name`, `callee`, etc. | string? | Captured fields from `$field:IDENTIFIER` patterns |

## Confidence Scoring

Confidence reflects how certain the parser is about a match:

| Score | Meaning |
|-------|---------|
| 1.0 | All elements matched with expected token kinds |
| 0.7–0.9 | Strong match — some elements matched via relaxed matching or optional elements absent |
| 0.5–0.7 | Plausible — partial structure, missing signals |
| 0.3–0.5 | Weak guess — minimal evidence |
| < 0.3 | Filtered out (not emitted) |

Confidence < 1.0 happens when:
- A keyword in the pattern matched an identifier token (relaxed match, e.g., `fn` not in `[keywords]`)
- Optional elements (`?` suffix) were absent
- Competing patterns resolved to a lower-scoring match

Agents can use confidence to decide whether to trust a match, refine the grammar, or ask an LLM for disambiguation.

## Error Cases

| Condition | Behavior |
|-----------|----------|
| File not found | stderr message, non-zero exit |
| Grammar not found | stderr message, non-zero exit |
| Invalid TOML | stderr message, non-zero exit |
| Missing `[[patterns]]` | stderr message, non-zero exit |
| Invalid `position` value | stderr message, non-zero exit |
| Negative weight value | stderr message, non-zero exit |
| `[comments] line` not an array of strings | stderr message, non-zero exit |
| `[comments]` block delimiter with wrong type | stderr message, non-zero exit |
| `[comments]` only one of `block_open`/`block_close` | stderr message, non-zero exit |
| `[comments]` prefix or delimiter longer than 8 chars | stderr message, non-zero exit |
| `[comments]` more than 16 line prefixes | stderr message, non-zero exit |
| Deprecated `exclude`/`not_preceded_by` field | stderr message, non-zero exit |
| `--node` without value | stderr message, non-zero exit |
| `query` without selector | stderr message, non-zero exit |
| `query` without grammar | stderr message, non-zero exit |
| Malformed query selector | stderr message, non-zero exit |
| No args | Usage message on stderr, non-zero exit (same as `--help`) |
