# Universal Lightweight Parser for AI Agents

## Project name
LASP - Language-Agnostic Structural Parser

## Overview
This project proposes a **Universal Lightweight Code Parser** designed for **AI agents**, tooling servers (such as MCP), and code intelligence systems.

Traditional parsers (compilers, AST generators) are:
* language-specific
* require full grammar definitions
* often fail on incomplete or partial code

However, AI agents frequently operate on:
* **partial code snippets**
* **incomplete files**
* **unknown languages**
* **generated fragments**

The goal of this project is to build a **lightweight, language-agnostic structural parser** that can extract useful code structure with minimal configuration and without full grammar definitions.

The parser acts as a **structural understanding layer for code**, enabling powerful analysis workflows without requiring traditional language parsers. It focuses on **structural patterns rather than full syntax correctness**.

---

## Core Idea: Structural Patterns
Instead of implementing a full compiler grammar, the parser relies on **universal structural patterns shared across most programming languages**.

Example pattern:
```
keyword identifier "(" args ")" block
```

This pattern matches functions in many languages:
- **Python:** `def add(a, b):`
- **Rust:** `fn add(a, b) {`
- **JavaScript:** `function add(a, b) {`
- **Go:** `func add(a, b int) {`

---

## Key Features
1. **Language-Agnostic**: No dedicated parser per language is required. It uses universal syntax patterns, configurable keyword lists, and structural delimiter tracking.
2. **Partial Code Support**: Tolerates incomplete code. For example, `fn add(a, b)` produces `Function(name="add", args=["a","b"], body=incomplete)`.
3. **Agent-Defined Parsing Specs**: Agents can dynamically define parsing rules for unknown languages or DSLs.
4. **Nested Parsing**: Parsing is performed in **layers**. Nodes may store block ranges rather than fully parsed children, keeping the initial parse fast and modular.
5. **Linear Performance**: Tokenization, index building, and pattern matching run in `O(N)` complexity where `N` is the number of tokens.

---

## 🏗 High-Level Architecture (Zig Implementation)

The parser is implemented as a **CLI tool written in Zig**, designed to process millions of lines parsed in seconds with a very low memory footprint via a streaming pipeline architecture.

```text
Source File
    │
    ▼
Tokenizer
    │
    ▼
Grammar Loader
    │
    ▼
Automaton Builder
    │
    ▼
Parser Engine
    │
    ▼
Event Stream
    │
    ▼
JSON Output / Partial AST
```

### 1. Tokenizer
The tokenizer reads characters and produces structural tokens using slice indices instead of string allocations. Token types include: `identifier`, `keyword`, `symbol`, `string`, `number`, `operator`, `newline`, `indent`, `comment`, `delimiter`.

Example token structure (Zig):
```zig
const TokenKind = enum { identifier, keyword, string, comment, symbol };

const Token = struct {
    kind: TokenKind,
    start: usize,
    end: usize,
};

const TokenPattern = union(enum) {
    keyword: []const u8,
    identifier,
    symbol: u8,
};
```

### 2. Structural Index
Before parsing, a structural index is built in a single pass recording token positions, delimiter pairs, and block regions.

Example Index for `function foo() { bar() }`:
```text
tokens:
  0 function
  1 foo
  2 (
  3 )
  4 {
  5 bar
  6 (
  7 )
  8 }
blocks:
  4 → 8
```

The Parser maintains a block stack for determining logic boundaries:
```zig
const Block = struct {
    kind: BlockKind, // e.g., braces, indentation
    start: usize,
};
```

### 3. Performance Characteristics
The design inherently favors speed and memory efficiency. Large repositories can be analyzed linearly:

| Operation      | Complexity   |
|----------------|--------------|
| tokenization   | O(N)         |
| index building | O(N)         |
| parsing        | O(N)         |
| nested parsing | O(matches)   |

### 4. Pattern Compilation & Automaton Builder
During startup, instead of matching patterns repeatedly, the parser performs a one-time compilation:
1. Loads the external grammar DSL file.
2. Formats pattern declarations into a Pattern AST.
3. Compiles patterns into a **deterministic automaton (Finite State Machine / Prefix Trie)**.

**Compilation Pipeline:**
```text
Grammar DSL
      │
      ▼
Pattern AST
      │
      ▼
Automaton Builder
      │
      ▼
Compiled State Machine
```
The compiled state machine is reused for evaluating all repository files symmetrically.

**Algorithm Detail:**
```text
for each pattern
    start at root (State 0)
    for each token in sequence
        create transition if missing
    mark final state with matching event
```

**Compiled Automaton Example** for pattern `"fn" IDENTIFIER "(":
```text
START (State 0)
  │ "fn"
  ▼
STATE 1
  │ IDENTIFIER -> capture(name)
  ▼
STATE 2
  │ "(" -> capture(args)
  ▼
MATCH → emit(Function)
```

**Zig Automaton Structures:**
```zig
const Transition = struct {
    token: TokenPattern,
    next_state: usize,
};

const State = struct {
    transitions: []Transition,
    event: ?EventKind,
};

const Automaton = struct {
    states: []State, // State 0 is the root.
};
```

**Pseudo-code Builder:**
```zig
fn addPattern(auto: *Automaton, pattern: Pattern) void {
    var state = 0;
    for (pattern.sequence) |token| {
        state = findOrCreateTransition(state, token);
    }
    auto.states[state].event = pattern.event;
}
```

### 5. Parser Engine (Streaming Execution)
The Parser processes streaming tokens sequentially against the compiled root automaton. It guarantees **linear parsing time `O(n)`** without any backtracking.

**Core Execution Loop:**
```zig
state = 0;

for token in tokens {
    if transition exists {
        state = next_state
    } else {
        state = 0 // Reset to root safely
    }

    if state has event {
        emit event
    }
}
```
This loop ensures the parser steps exactly once per token, maximizing speed and scaling effortlessly across massive repositories.

### 6. Memory Strategy & Parallelization
To stay highly performing, the parser uses Zig's Arena Allocator (`std.heap.ArenaAllocator`) for fast allocation and cheap deallocation without the memory footprint of classical ASTs.
Repository parsing can be deeply parallelized:
```zig
std.Thread.spawn(...) // each worker thread indexes separate files.
```

---

## 📜 Grammar DSL Specification

The system uses a simple YAML/TOML structured DSL for defining **structural elements** over robust language parsing logic.

### Grammar File Layout
A grammar file consists of: `language`, `keywords`, `patterns`, `blocks`.

The system supports a literal mapping pattern (TOML) or an explicit node capture mapping (YAML).

**Example (TOML Literal Mapping - Python):**
```toml
[language]
name = "python"

[keywords]
function = ["def"]
class = ["class"]
import = ["import", "from"]

[[patterns]]
type = "function"
sequence = ["def", "identifier", "("]

[[patterns]]
type = "call"
sequence = ["identifier", "("]
```

**Example (TOML Literal Mapping - Rust):**
```toml
[language]
name = "rust"

[keywords]
function = ["fn"]
struct = ["struct"]
import = ["use"]

[[patterns]]
type = "function"
sequence = ["fn", "identifier", "("]

[[patterns]]
type = "struct"
sequence = ["struct", "identifier"]
```

**Example (YAML Tree Capture Mapping):**
```yaml
nodes:
  Function:
    start: ["fn", "def", "function", "func"]
    capture:
      name: identifier
      args: parentheses
      body: block
```

### Available Token Primitives
- **Keywords**: `"fn"`, `"class"`, `"import"`.
- **Identifiers**: `IDENTIFIER`.
- **Exact Identifiers**: `"Config:IDENTIFIER"` — matches an identifier token with exact text (no capture).
- **Symbols**: `"{"`, `":"`, `","`.

### Identifier Captures
Captures allow patterns to extract values from tokens. Represented by `$name:IDENTIFIER`.
Pattern: `"fn" $name:IDENTIFIER "("` 
Outputs `Capture` struct:
```zig
const Capture = struct { name: []const u8, position: usize };
```

### Exact Identifier Matching
To match an identifier with specific text without capturing, use `Name:IDENTIFIER`:
```toml
sequence = ["Config:IDENTIFIER", ".", "$method:IDENTIFIER", "("]
```
This matches only when the identifier text is exactly `"Config"`. Unlike keyword literals, this matches `.identifier` tokens — useful for names that aren't language keywords.

### Block Definitions
Blocks describe structural scopes either by tokens (`{ }`) or explicitly mapped for python/YAML logic:
```
block indentation: true
```

### Best Practices for Grammar Authors
To ensure deterministic execution and prevent runaway states:
1. **Structure over Syntax:** Identify key operational nodes. Avoid parsing exhaustive mathematical expressions.
2. **Keep patterns short:** `"fn" IDENTIFIER "("\n` works perfectly while evaluating the entirety of arguments inside the pattern can fail gracefully.
3. **Prefer Structural Triggers:** Begin matches with distinct keywords (`fn`, `class`, `import`).
4. **Avoid Ambiguity:** Try to map `IDENTIFIER IDENTIFIER` rarely, as sequential typeless names appear in countless unstructured contexts.

---

## 🎯 Probabilistic Parsing
LASP implements probabilistic confidence scoring — each structural match carries a confidence score from 0.0 to 1.0 reflecting how certain the parser is about the match.

Instead of asking *"Is this definitely a function?"*, the parser asks: *"How likely is this structure to represent a function?"*

### How Confidence Works (Implemented)

**Relaxed keyword matching**: When a keyword in a pattern (e.g., `"fn"`) encounters an identifier token with matching text (because `fn` isn't in the `[keywords]` section), it matches with reduced weight (0.1 instead of 0.5). This produces confidence < 1.0.

**Optional elements**: Sequence elements suffixed with `?` boost confidence when present but don't prevent matching when absent. Pattern `["fn", "$name:IDENTIFIER", "(?"]` matches `fn add` with confidence ~0.78 and `fn add(` with confidence 1.0.

**Competing patterns**: When multiple patterns share a prefix and reach terminal states for overlapping token ranges, the engine buffers candidates and emits only the best match (highest confidence → longest match → grammar order).

**Configurable weights**: Grammar authors can override default evidence weights via a `[weights]` section.

### Evidence Weights (Defaults)

| Feature          | Weight |
|------------------|--------|
| keyword          | +0.5   |
| identifier       | +0.2   |
| symbol           | +0.2   |
| block            | +0.3   |
| relaxed_keyword  | +0.1   |

### Confidence Thresholds
| Confidence   | Interpretation |
|--------------|----------------|
| 1.0          | Perfect match — all elements matched with expected token kinds |
| 0.7 – 0.9   | Strong match — relaxed keywords or missing optional elements |
| 0.5 – 0.7   | Probable match — partial structure |
| 0.3 – 0.5   | Weak match |
| < 0.3       | Ignored (filtered out) |

### AI Integration Advantages
Confidence scores allow agents operating autonomously over massive unknown dependencies to:
1. Systematically choose the most statistically likely interpretation
2. Request deeper language model analysis exclusively on nodes where `confidence < 0.8`
3. Refine grammars iteratively — low confidence signals missing keywords or patterns

### Future Scoring Enhancements (Planned)
- **Noise penalty**: Unexpected tokens between matched elements reduce confidence (infrastructure in place, capped at 0.5)
- **Context evaluation**: Framework-aware scoring (e.g., `router.get("/users")` → endpoint detection)
- **Frequency-based thresholds**: Repeated similar structures build dynamic confidence over a repository

---

## 📉 Output Format & Example Workflow

The parser functions as a CLI that generates JSON Event Streams, enabling simple lazy parsers or embeddings to extract specific elements fast.

**Commands:**
```bash
code-parser parse file.rs --grammar grammars/rust.toml
code-parser parse-dir ./repo --grammar-dir grammars/
```

**Output JSON Code snippet Events:**
```json
{
  "events": [
    {
      "type": "function",
      "name": "login",
      "start": 120,
      "end": 240,
      "confidence": 0.94
    },
    {
      "type": "call",
      "callee": "validate",
      "pos": 180,
      "parent_range": [120, 240]
    }
  ]
}
```

### 🤖 AI Agent Workflow & MCP Integration

The exact problem this tool solves is empowering AI agents to understand sprawling, messy, or entirely custom codebases. Rather than sending massive raw text files to the LLM (which breaks context windows) or relying on fixed AST tools (which fail on custom DSLs), the agent can organically author its own parser.

**The Autonomous Agent Loop:**
1. **Discovery:** The AI Agent encounters an unknown language, framework, or massive file.
2. **Grammar Generation:** The Agent dynamically writes a lightweight `.toml` or `.yaml` syntax grammar defining exactly what key structural boundaries it needs to see (e.g. `pattern sql = "SELECT" IDENTIFIER`).
3. **Execution (MCP Tool):** The Agent dispatches LASP via an MCP Tool, executing the engine against the codebase using the newly drafted grammar.
```json
{
  "spec": "my_sql_extraction_rule",
  "code": "partial snippet"
}
```
4. **Structured Evaluation:** LASP extremely quickly returns the localized JSON outputs, feeding the structured data immediately back to the Agent.
5. **Insights:** The Agent evaluates the exact lines, context scores, and parent ranges without reading the raw code text, looping back to refine its queries or vectorizing the results for Long Term Memory organically.

---

## 📂 Project Structure Example
```text
src/
 ├─ main.zig
 ├─ cli/
 │   └─ args.zig
 ├─ grammar/
 │   ├─ loader.zig
 │   └─ compiler.zig
 ├─ parser/
 │   ├─ tokenizer.zig
 │   ├─ automaton.zig
 │   ├─ engine.zig
 │   └─ events.zig
 └─ output/
     └─ json.zig
grammars/
 ├─ python.toml
 ├─ rust.toml
 ├─ javascript.toml
 └─ go.toml
```

---

## 🚀 Development Roadmap & Future Extensions

### Roadmap
- **Phase 1**: CLI, file reader, tokenizer, JSON output operations.
- **Phase 2**: Grammar loader, Trie automaton builder, token-guided pattern matching.
- **Phase 3**: Multi-language support, identifier capture, block boundary logic.
- **Phase 4**: Parallel repository parsing, integration with MCP, chunk embedding generation.

### Future Extensions
- **Repository Pattern Discovery**: Detecting structural similarities algorithmically to extract DSLs organically.
- **Structural Embeddings**: Encoding graph structures into LLM vector dimensions.
- **Cross-language Structural Indexing**: Querying architecture beyond single language ecosystems (Call graph, dependency graphs, doc comment extraction).
- **Self-learning Syntax Rules**: Having LLMs observe missing patterns to infer updated weights in probabilistic rules.
- **Vector Search Integration**.
