# LASP Usage Guide for Coding Agents

## What LASP Does

LASP is a language-agnostic structural parser. Given source code and an optional TOML grammar file, it detects structural constructs (functions, calls, structs, imports) and outputs them as JSON events. No full AST — just the structural skeleton.

## Binaries

| Binary | Path | When to use |
|--------|------|-------------|
| Stable | `.bin/lasp` | Known-good build, safe for analysis |
| Development | `zig-out/bin/lasp` | Latest build after `zig build` |

Build the development binary: `zig build`

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

### Structural parsing (with grammar)

```bash
.bin/lasp parse <file> --grammar <grammar.toml>
# or short form:
.bin/lasp parse <file> -g <grammar.toml>
```

Returns structural events with captures, confidence scores, and position info:

```json
{ "events": [
  { "type": "function", "start": 0, "end": 15, "line": 1, "col": 0, "confidence": 1.00, "name": "add" }
] }
```

## Available Grammars

| File | Language | Notes |
|------|----------|-------|
| `tests/fixtures/grammars/zig.toml` | Zig | Functions, structs, calls |

## Writing a Grammar

Grammars are TOML files with these sections:

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

### Phase 3 features (position and exclude)

Constrain patterns to match only at column 0 (line start):

```toml
[[patterns]]
type = "function"
sequence = ["$name:IDENTIFIER", "("]
position = "start"
```

Exclude matches preceded by specific tokens:

```toml
[[patterns]]
type = "function"
sequence = ["$name:IDENTIFIER", "("]
position = "start"
exclude = ["-spec", "-type"]
```

### Sequence elements

| Element | Matches |
|---------|---------|
| `"fn"` | Exact keyword text |
| `"("` | Exact symbol/delimiter |
| `"identifier"` | Any identifier token |
| `"$name:IDENTIFIER"` | Identifier, captured as `name` field |

## Practical Workflows

### Explore an unfamiliar file

```bash
# See all tokens
.bin/lasp parse src/parser/engine.zig

# See structural events with the Zig grammar
.bin/lasp parse src/parser/engine.zig -g tests/fixtures/grammars/zig.toml
```

### Write a grammar for a new language

1. Run `lasp parse <file>` without a grammar to see the raw token stream
2. Identify the keyword/symbol patterns that mark structural constructs
3. Write a `.toml` grammar with those patterns
4. Run `lasp parse <file> -g <grammar.toml>` and check the output
5. Iterate: adjust patterns, add captures, tune position/exclude constraints

### Compare stable vs development output

```bash
diff <(.bin/lasp parse file.zig -g grammar.toml) <(zig-out/bin/lasp parse file.zig -g grammar.toml)
```

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
| `block_start` | int? | Byte offset of enclosing block open delimiter (if inside a block) |
| `name`, `callee`, etc. | string? | Captured fields from `$field:IDENTIFIER` patterns |

## Error Cases

| Condition | Behavior |
|-----------|----------|
| File not found | stderr message, non-zero exit |
| Grammar not found | stderr message, non-zero exit |
| Invalid TOML | stderr message, non-zero exit |
| Missing `[[patterns]]` | stderr message, non-zero exit |
| Invalid `position` value | stderr message, non-zero exit |
| No args | Usage message on stderr, non-zero exit |
