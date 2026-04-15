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

### Position constraints

Restrict a pattern to match only at column 0 (line start):

```toml
[[patterns]]
type = "function"
sequence = ["$name:IDENTIFIER", "("]
position = "start"
```

### Exclusion patterns

Discard matches preceded by specific tokens:

```toml
[[patterns]]
type = "function"
sequence = ["$name:IDENTIFIER", "("]
position = "start"
exclude = ["-spec", "-type"]
```

### Not-preceded-by constraint

Discard matches where the immediately preceding token matches:

```toml
[[patterns]]
type = "function"
sequence = ["$name:IDENTIFIER", "("]
position = "start"
not_preceded_by = ["fun", "="]
```

Unlike `exclude` (which checks a 4-token lookback buffer), `not_preceded_by` checks only the single immediately preceding non-skip token. Use it for short keywords and operators.

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

## Workflow: Analyze an Unfamiliar Codebase

1. Run `.bin/lasp parse <file>` without a grammar to see raw tokens
2. Identify keyword/symbol patterns that mark structural constructs
3. Write a `.toml` grammar with those patterns
4. Run `.bin/lasp parse <file> -g <grammar.toml>` and check the output
5. Iterate: adjust patterns, add captures, tune position/exclude constraints

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
| No args | Usage message on stderr, non-zero exit |
