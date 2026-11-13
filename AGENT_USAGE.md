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

When `-g` is omitted, grammars load from `.lasp/grammars` in the current
directory (the default grammar source): every grammar whose
`[language] extensions` suffix-match the target basename runs — one match
behaves exactly like explicit `-g`; several matches emit one
`{ "file", "grammar", "events" }` entry per matching grammar (sorted by grammar
filename); zero matches fall back to raw-token output. `--names-only` with
several matches is an error. Stdin (`-`) never uses the default.

Returns structural events with captures, confidence scores, and position info:

```json
{ "events": [
  { "type": "function", "start": 0, "end": 15, "line": 1, "confidence": 1.00, "col": 0, "name": "add" }
] }
```

### NDJSON output (`--jsonl`)

Opt-in, one-JSON-value-per-line framing — no document wrapper. Each record is
the same object as the corresponding Wrapped_Form element, with exactly one
`\n` terminator, so records are independently greppable and streamable:

```bash
.bin/lasp parse file.zig -g examples/grammars/zig.toml --jsonl
.bin/lasp parse-dir <dir> --grammar-dir <gdir> --jsonl
.bin/lasp query 'function' file.zig -g examples/grammars/zig.toml --jsonl
```

- Single-file `parse`: one line per structural event; the raw-token fallback
  emits one line per token; zero events/tokens ⇒ zero bytes.
- `parse-dir` and multi-grammar defaults: every event of every
  `{ "file", "grammar", "events" }` entry flattens into its own line whose
  FIRST two fields are `file` and `grammar` (remaining fields byte-identical to
  the wrapped event); entries with no events emit nothing.
- The trailing document newline that Wrapped_Form adds is suppressed in
  `--jsonl` mode (each record already ends in `\n`).
- Mutually exclusive with `--names-only` (usage error). Rejected on
  `version`/`help` — `--jsonl --version` and `--jsonl --help` included.
  Flag off ⇒ output byte-for-byte identical to today's wrapped JSON.



Parses every file in a directory tree whose extension is declared by a grammar
in `--grammar-dir`, emitting one JSON array of per-file results:

```bash
   bin/lasp parse-dir <dir> --grammar-dir <grammar-dir> [--jsonl]
```

Behavior:
- Recursively walks `<dir>`; every regular file is checked against every loaded
  grammar's `[language] extensions` list (`std`em.endsWith` suffix match on the
  basename — `.erl` matches `foo.erl`; the dot-less form like `erl` is the
  broader documented suffix).
- A file is parsed once **per matching grammar** (multi-grammar-per-extension
  yields one entry per grammar), and unmatched files are skipped silently.
- Output is a JSON array; each entry is `{ "file", "grammar", "events" }`
  where `events` is byte-identical to what single-file
  `.bin/lasp parse <file> -g <grammar>` emits for that file.
- `--node <type>` filters each entry's `events` (empty array when nothing
  matches). `--names-only` is not wired in dir mode (deferred).
- No `--grammar-dir` ⇒ the default `.lasp/grammars` is used when present (same
  loader, order, and behavior); with no default dir either, every file matches
  nothing ⇒ `[]` with exit zero.
- Grammars are loaded in sorted filename order; a malformed grammar aborts with
  the usual grammar error message, naming the offending grammar path.

```json
[ { "file": "a.erl", "grammar": "erlang.toml", "events": [ { "type": "function", "start": 0, "end": 13, "line": 1, "confidence": 1.00, "col": 0 } ] },
  { "file": "sub/c.erl", "grammar": "erlang.toml", "events": [ { "type": "function", "start": 0, "end": 13, "line": 1, "confidence": 1.00, "col": 0 } ] } ]
```

Target paths may be relative, absolute, or carry a trailing slash.

### Node type filtering (`--node` / `-n`)

Emit only structural events matching a specific type name:

```bash
.bin/lasp parse file.zig -g examples/grammars/zig.toml --node function
.bin/lasp parse file.zig -g examples/grammars/zig.toml -n call
```

The comparison is case-insensitive. When the filter matches zero events, the output is a valid JSON object with an empty events array. When no grammar is specified, `--node` is silently ignored and raw token JSON is emitted.

### Alternatives output (`--alternatives`)

Opt-in, parse-only boolean flag: every winning event gains an `alternatives` JSON array listing the losing competitors from the same overlapping region, each with only `type`, `confidence`, and its captures (no position fields). The winner keeps all its fields. When the flag is absent, output is byte-for-byte identical and no `alternatives` key appears. The flag is rejected on `query` and ignored by `--names-only`.

```bash
.bin/lasp parse file.zig -g examples/grammars/zig.toml --alternatives
```

```json
{ "type": "function", "start": 0, "end": 10, "confidence": 0.90, "name": "foo",
  "alternatives": [ { "type": "call", "confidence": 0.60, "callee": "foo" } ] }
```



### Resemblance output (`--resemble`)

Opt-in, parse-only boolean flag: scores each token's partial membership against the grammar's own `char_class_run` kinds (relaxed recognition) and surfaces the best above-floor match as an advisory alternative on the affected event. A token that no kind fully recognizes (e.g. `0x01` under a `number` kind whose set is `0-9`) appears as a low-confidence `number` candidate — the grammar is the feature basis, the binary supplies only the scoring.

`--resemble` implies `--alternatives` collection for the affected regions; resemblance candidates appear in the event's `alternatives` array with `"source": "resemblance"`, `"resembled_kind"` (the resembled kind name), and `"membership"` (the score, which equals the confidence). Grammar-matched candidates win their region unchanged; resemblance can never become the winner or create a primary event the grammar did not license. Rejected on `query`; ignored by `--names-only`; no char-class kinds ⇒ no resemblance.

```bash
.bin/lasp parse file.txt -g grammars/num.toml --resemble
```

```json
{ "type": "literal", "start": 0, "end": 4, "confidence": 1.00,
  "alternatives": [ { "type": "number", "confidence": 0.83,
                      "source": "resemblance", "resembled_kind": "number",
                      "membership": 0.83 } ] }
```

Without the flag, output is byte-for-byte identical and no `source`/`resemblance` keys appear. See `tests/fixtures/grammars/resemblance.toml` (and `examples/grammars/erlang_tokens.toml`/`forth_tokens.toml` for `[tokens]` grammars).

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
# Count functions in a file — --jsonl emits one JSON event per line for exact counts
.bin/lasp parse src/main.zig -g examples/grammars/zig.toml --node function --jsonl | wc -l
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

Output for a released build:

```
lasp 0.3.0
```

Output for a development build (the working tree, or any build whose version or tree does not match the latest release):

```
lasp 0.3.0-dev+a2ff0ae
```

The version is embedded at build time. A build is **released** (plain `X.Y.Z`) only when the current commit carries a **git release tag matching the version** (`v0.3.0` or `0.3.0` for `0.3.0`) AND `build.zig.zon`'s version equals the latest dated `CHANGELOG.md` release AND the source tree is clean (git). Any other build reports `X.Y.Z-dev+<short-commit>` — including a clean commit past a release that carries no tag (the previously misreported mid-cycle case). When no git facts are available (no `.git`, no flake revision — e.g. a tarball build) it falls back to the plain version. The rule lives in `build.zig`; the Nix flake supplies commit/dirty hermetically from the flake revision (no `git` in the sandbox). The flake's default outputs (`packages.default`, `packages.lasp`) pass `-Dgit_tagged=false`, so an ordinary `nix build` reports dev. A released Nix build is produced by building the dedicated `packages.released` output (`nix build .#released`) from the tagged, clean release commit — it passes `-Dgit_tagged=true`, making it the Nix equivalent of the local tagged `zig build`. The clean-tree and changelog-match conditions still apply, so a dirty or version-mismatched `nix build .#released` still reports dev. To release: tag the release commit (`git tag vX.Y.Z`), bump `version` in `build.zig.zon`, and add a `CHANGELOG.md` entry (Keep a Changelog format). `--version`/`-V` is also accepted among other flags and exits before reading any file.

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

Query events using CSS-selector-inspired syntax. Requires a grammar (`-g`), or a
default in `.lasp/grammars` whose `[language] extensions` suffix-match the file
(one match behaves exactly like explicit `-g`; several matches emit one
`{ "file", "grammar", "events" }` entry per matching grammar; zero matches or an
absent default dir keep the `requires --grammar/-g` error).

### Syntax

```
lasp query '<selector>' <file> -g <grammar.toml> [--names-only] [--jsonl]
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

# Substring operators: contains / prefix / suffix (quoted values only)
.bin/lasp query 'function[name~="deadline"]' file.zig -g examples/grammars/zig.toml
.bin/lasp query 'function[name^="test_"]' file.zig -g examples/grammars/zig.toml
.bin/lasp query 'call[callee$="export_quotes"]' file.zig -g examples/grammars/zig.toml

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
- `[field>N]` / `[field=N]` / `[field!=N]` — numeric conditions on integer count fields (`[[patterns.count]]`): unquoted numeric values compare against the event's integer fields; `!=` includes events lacking the field, `=`/`>` exclude them (a `"..."`-quoted value always compares against string captures)
- `[field~="text"]` — contains: include events whose capture `field` contains `text` as a substring (empty `text` includes every present-string field)
- `[field^="text"]` — prefix: include events whose capture `field` starts with `text`
- `[field$="text"]` — suffix: include events whose capture `field` ends with `text` — the fix for dotted captures: `[callee$="export_quotes"]` matches a `callee` of `client.export_quotes`
- Substring operators accept a **quoted string value only**; an unquoted value is a parse error (`ExpectedQuotedValue`). Against an absent field or a non-string field (e.g. an integer count), they exclude.
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
### Language metadata (`[language]`)

`name` is optional display metadata. `extensions` is an array of file-extension
strings that selects which files the grammar applies to under `parse-dir`:

```toml
[language]
name = "erlang"
extensions = [".erl", ".escript"]
```

Absent `[language]`, absent `extensions`, and `extensions = []` all mean the
grammar matches no files in dir mode. Each entry must be a non-empty string;
anything else is a grammar error. Extensions are inert outside `parse-dir`
(single-file `parse` and `query` ignore them entirely).

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


### Tokens section (`[tokens]`)

Without `[tokens]`, LASP tokenizes with a built-in C-family profile. A grammar may replace that vocabulary with its own ordered kinds; each key declares exactly one recognizer:

```toml
[tokens]
ident = { char_class_run = { start = "a-zA-Z_", continue = "a-zA-Z0-9_" } }
number = { char_class_run = { start = "0-9", continue = "0-9." } }
quoted_atom = { delimited_span = { open = "'", close = "'" } }
arrow = { literal_set = ["->", "=>"] }
```

- `char_class_run`: greedy run of one `start` char then `continue` chars (defaults to `start`); char-set specs support literals and ranges (`a-zA-Z0-9_`).
- `delimited_span`: `open`…`close` with optional single-char `escape`; unclosed spans extend to EOF.
- `literal_set`: longest matching literal (non-empty members).
- Declaration order is matching priority; the first recognizer that matches at a position wins. Custom kind names are allowed.
- Patterns reference kinds by name: bare `ident`, exact-text `foo:ident`, or typed capture `$field:ident`.
- A grammar without `[tokens]` is byte-for-byte identical to pre-feature output. The `[keywords]` section stays a keyword overlay over identifier-run kinds.
- Invalid declarations (empty/inverted char sets, empty spans/literal sets, zero or multiple recognizers, empty names) are grammar errors.
- See `examples/grammars/erlang_tokens.toml` and `examples/grammars/forth_tokens.toml`.
### Sequence elements

| Element | Matches |
|---------|---------|

| `"fn"` | Exact keyword text (also matches identifiers with reduced confidence) |
| `"("` | Exact punctuation character — operator, symbol, or delimiter (`+ - * / = < > ! & \| ^ % ~ ( ) { } [ ] , ; : . @ ?`) |
| `"identifier"` | Any identifier token |
| `"$name:IDENTIFIER"` | Identifier, captured into `name` field |
| `"$name:IDENTIFIER(sep=...)"` | **Removed** — parenthesized capture parameters are rejected (`ParenthesizedCaptureParam`); use `[[patterns.capture]]` tables |
| `"$name:IDENTIFIER(suffix=...)"` | **Removed** — see `[[patterns.capture]]` |
| Same `type` on multiple `[[patterns]]` | Alternatives of one type; overlap collapses to longest match → grammar order |


### Capture modifier tables (`[[patterns.capture]]`)

```toml
[[patterns]]
type = "fn"
sequence = ["identifier", "$n:IDENTIFIER"]

[[patterns.capture]]
field = "n"
separator = "."
suffix = "!?"
```

Attaches separator/suffix span behavior to a bare capture (the removed `$field:KIND(sep=...)` form). `field` must name a capture; one table per field; at least one of `separator`/`suffix` (1–8 bytes).

### Count tables (`[[patterns.count]]`)

```toml
[[patterns.count]]
field = "args"
open = "("
close = ")"
separator = ","
```


### Region extent (`[[patterns.extent]]`)
Declares where a matched construct's region ends; the engine emits that byte offset as an author-named integer field:
```toml
[[patterns]]
type = "function"
sequence = ["identifier", "$n:IDENTIFIER", "("]

[[patterns.extent]]
field = "body"
open = "{"
close = "}"
```
- **Balanced mode** (`open` + `close`): depth-balanced forward scan to the matching close delimiter; extent = that close token's end. Unclosed, or no `open` at/after the match, ⇒ EOF. `open == close` ⇒ no nesting (first occurrence opens, next closes).
- **Terminator mode** (`terminator`, optional `at_column`): extent = end of the first token byte-equal to `terminator`, restricted to 0-based `at_column` when supplied; none found ⇒ EOF.
- Output: bare JSON integer (never quoted), queryable with numeric conditions (`[body>100]`), `--names-only` prints the first string capture and falls back to this integer only when the event has no string capture; `block_end` stays `null` (extent is the single region-end answer).
- Validation: mode conflict / missing mode / half-balanced / `field` empty or >64 bytes / delimiter empty or >8 bytes / `at_column` without terminator or outside 0–65535 / field collision with captures·counts / >1 table per pattern — each a load-time grammar error.
- No extent table ⇒ byte-identical output.

### Prior (per-pattern confidence multiplier)

An optional `prior` key on a `[[patterns]]` entry multiplies that pattern's evidence confidence: `final = clamp(evidence × prior, 0, 1)`, applied before the 0.3 filter and before competing-candidate selection. Valid range `(0.0, 2.0]`, default `1.0` (exact no-op). Below 1.0 demotes an interpretation (mild demotion keeps it visible at reduced confidence; strong demotion can drop it below the 0.3 filter); above 1.0 boosts toward — never past — 1.0.

```toml
[[patterns]]
type = "call"
sequence = ["$callee:IDENTIFIER", "("]
prior = 0.5
```

Use it to disambiguate identical-sequence interpretations (e.g. a column-0 `function` at `prior = 0.9` vs `call` at `0.5`) without hard blacklists. Out-of-range or non-numeric values are grammar errors.

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
| Downstream reader closes the pipe early (e.g. `\| head`, `\| less` quit) | Broken pipe (EPIPE) is a clean exit: nothing on stderr, zero exit — like `grep`/`jq`. Other stdout write failures (disk full, I/O error) still error non-zero |
| `parse-dir` target is missing or not a directory | `directory not found` on stderr, non-zero exit |
| `--grammar-dir` is missing or not a directory | `grammar directory not found` on stderr, non-zero exit |
| Malformed grammar inside `--grammar-dir` | grammar error message naming the offending `.toml` path, non-zero exit |
| `[language] extensions` not an array of non-empty strings | stderr message, non-zero exit |
| `--jsonl` combined with `--names-only` | `error: --jsonl and --names-only are mutually exclusive` on stderr, non-zero exit (order-independent) |
| `--jsonl` with `version`/`help` output | `error: --jsonl is only supported on parse, parse-dir, and query commands` on stderr, non-zero exit (incl. `--jsonl --version` / `--jsonl --help`) |
| Substring operator (`~=`, `^=`, `$=`) with an unquoted value | stderr message, non-zero exit |
