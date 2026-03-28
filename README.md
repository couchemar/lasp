# Universal Lightweight Parser for AI Agents

## Project name

LASP - Language-agnostic structural parser

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

The parser focuses on **structural patterns rather than full syntax correctness**.

---

# Goals

The parser is designed to:

* Parse **partial code fragments**
* Work with **unknown or mixed languages**
* Allow **LLM-generated parsing specifications**
* Support **nested analysis**
* Operate **extremely fast**
* Produce **simple structural ASTs**

Typical use cases include:

* AI coding agents
* MCP tools
* code search systems
* repository analysis
* framework detection
* automated refactoring tools

---

# Core Idea

Instead of implementing a full compiler grammar, the parser relies on **universal structural patterns shared across most programming languages**.

Example pattern:

```
keyword identifier "(" args ")" block
```

This pattern matches functions in many languages:

Python

```
def add(a, b):
```

Rust

```
fn add(a, b) {
```

JavaScript

```
function add(a, b) {
```

Go

```
func add(a, b int) {
```

By focusing on structure rather than strict grammar, the parser can operate across languages.

---

# Key Features

### Language-Agnostic

No dedicated parser per language is required.

Instead, the parser uses:

* universal syntax patterns
* configurable keyword lists
* structural delimiter tracking

---

### Partial Code Support

The parser tolerates incomplete code.

Example:

```
fn add(a, b)
```

This still produces:

```
Function(name="add", args=["a","b"], body=incomplete)
```

---

### Agent-Defined Parsing Specs

Agents can dynamically define parsing rules.

Example spec:

```yaml
node Function:
  start: ["fn", "def", "function", "func"]
  capture:
    name: identifier
    args: parentheses
    body: block
```

This allows agents to parse **unknown languages or DSLs**.

---

### Nested Parsing

Parsing is performed in **layers**.

Example workflow:

1. Parse functions
2. Parse calls inside functions
3. Parse SQL queries inside calls

Example structure:

```
Function foo
 ├ Call bar
 └ Call baz
```

This avoids building heavy compiler ASTs while preserving useful structure.

---

# Architecture

```
                 Code Input
                     │
                     ▼
               Tokenizer
                     │
                     ▼
           Structural Index Builder
                     │
                     ▼
            Parser Automaton Engine
                     │
                     ▼
              Partial AST Output
                     │
                     ▼
          Optional Nested Parsers
```

---

# Tokenizer

The tokenizer is intentionally generic.

Token types:

| Token Type | Example            |
| ---------- | ------------------ |
| identifier | foo                |
| keyword    | if                 |
| symbol     | { } ( )            |
| string     | "hello"            |
| number     | 123                |
| operator   | + - *              |
| newline    | \n                 |
| indent     | Python indentation |
| comment    | //                 |
| delimiter  | , ;                |

This minimal tokenizer works for most languages.

---

# Structural Index

Before parsing, the system builds a **structural index** in a single pass.

The index records:

* token positions
* delimiter pairs
* block regions

Example:

```
function foo() {
    bar()
}
```

Index:

```
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

The index allows extremely fast nested parsing.

---

# Parser Automaton

Parsing rules are compiled into a **finite state machine**.

Example rule:

```
Function:
keyword identifier "(" args ")" block
```

Compiled automaton:

```
STATE 0
  keyword → STATE 1

STATE 1
  identifier → capture(name) → STATE 2

STATE 2
  "(" → capture(args) → STATE 3

STATE 3
  block → EMIT(Function)
```

During parsing:

```
for token in tokens:
    automaton.step(token)
```

Complexity:

```
O(N)
```

Where `N` is number of tokens.

---

# Lightweight Parser Syntax (DSL)

The parser uses a simple YAML-based DSL for rules.

Example:

```yaml
nodes:

  Function:
    start: ["fn","def","function"]
    capture:
      name: identifier
      args: parentheses
      body: block

  Call:
    pattern:
      identifier "(" args ")"
```

Supported primitives:

| Primitive   | Meaning                   |
| ----------- | ------------------------- |
| identifier  | variable or function name |
| string      | quoted string             |
| number      | numeric literal           |
| parentheses | balanced `()`             |
| block       | `{}` or indentation block |
| line        | until newline             |
| until       | read until token          |

---

# Nested Parsing

Nodes may store **ranges** rather than fully parsed children.

Example node:

```json
{
  "type": "Function",
  "name": "foo",
  "args": ["a","b"],
  "body_start": 120,
  "body_end": 340
}
```

Nested parsers can run on the body region:

```
source[120:340]
```

This keeps parsing fast and modular.

---

# Output Format

The parser produces a **lightweight structural AST**.

Example:

```json
{
  "functions": [
    {
      "type": "Function",
      "name": "foo",
      "args": ["a", "b"],
      "calls": [
        {"name": "bar"},
        {"name": "baz"}
      ]
    }
  ]
}
```

Alternative minimal representation:

```json
{
  "type": "Function",
  "name": "foo",
  "args": ["a","b"],
  "body_range": [120,340]
}
```

This format supports lazy nested parsing.

---

# Structural Patterns

The parser relies on a small set of universal patterns.

Examples:

### Function

```
(keyword)? identifier "(" args ")" block
```

### Class

```
(keyword)? identifier block
```

### Import

```
keyword path
```

### Assignment

```
identifier "=" expression
```

These patterns cover the majority of code structures across languages.

---

# Performance

Performance characteristics:

| Operation      | Complexity |
| -------------- | ---------- |
| tokenization   | O(N)       |
| index building | O(N)       |
| parsing        | O(N)       |
| nested parsing | O(matches) |

Large repositories can be analyzed efficiently.

---

# Example Workflow for AI Agents

Agent request:

```
Find functions that call the database
```

Processing pipeline:

```
code
 ↓
build structural index
 ↓
parse functions
 ↓
parse calls inside bodies
 ↓
detect SQL patterns
```

The code file itself is scanned only once.

---

# Integration with MCP

Example MCP tool:

```
parse_code(spec, code)
```

Request:

```json
{
  "spec": "extract_functions",
  "code": "partial snippet"
}
```

Response:

```json
{
  "functions":[
    {"name":"add","args":["a","b"]}
  ]
}
```

---

# Future Extensions

Possible advanced features include:

* self-learning syntax rules
* repository pattern discovery
* framework detection
* structural embeddings
* vector search integration
* cross-language structural indexing

---

# Summary

This project introduces a new approach to code parsing:

* **lightweight**
* **language-agnostic**
* **fragment tolerant**
* **LLM-driven**
* **structural instead of grammatical**

It is designed specifically for **AI agents and code intelligence systems**, where speed, flexibility, and partial understanding are more valuable than full compiler correctness.

The parser acts as a **structural understanding layer for code**, enabling powerful analysis workflows without requiring traditional language parsers.


## Structural parsing

Why structural parsing fits

The approach is extracts syntactic structure from code:

* functions
* blocks
* calls
* imports
* assignments
* delimiters

It operates on code shape and patterns, not meaning.

Example it detects:

identifier "(" args ")"

→ function call structure

Even if the parser does not know what the function means.

So the parser understands structure, not semantics.

## Best description

Best description

"Lightweight structural code parser"

or

"Language-agnostic structural parser"


# Lightweight Grammar-Driven Code Parser (Zig)

A fast, language-agnostic **structural code parser** designed for AI tooling and code intelligence systems.

The parser is implemented as a **CLI tool written in Zig** and driven by **external grammar files**, allowing it to parse many programming languages without recompiling the binary.

This project is intended to support **AI coding agents and MCP-based systems** by providing fast structural extraction of code elements such as:

* functions
* classes
* imports
* calls
* blocks
* comments

Instead of building full ASTs like traditional compilers, the parser performs **lightweight structural parsing**, producing an **event stream** describing code structure.

---

# Goals

The parser is designed to be:

* **Fast** — linear-time parsing
* **Language-agnostic** — grammars provided at runtime
* **Memory efficient** — streaming architecture
* **Simple** — minimal grammar complexity
* **Extensible** — new languages require only grammar files
* **AI-friendly** — structured output suitable for embeddings and code indexing

---

# High Level Architecture

The parser follows a streaming pipeline.

```
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
JSON Output
```

Key principle:

```
Parser engine = generic
Grammar = runtime data
```

---

# Project Structure

Example layout:

```
src/
 ├─ main.zig
 ├─ cli/
 │   └─ args.zig
 │
 ├─ grammar/
 │   ├─ loader.zig
 │   └─ compiler.zig
 │
 ├─ parser/
 │   ├─ tokenizer.zig
 │   ├─ automaton.zig
 │   ├─ engine.zig
 │   └─ events.zig
 │
 └─ output/
     └─ json.zig

grammars/
 ├─ python.toml
 ├─ rust.toml
 ├─ javascript.toml
 └─ go.toml
```

---

# CLI Usage

Basic usage:

```
code-parser parse file.rs --grammar grammars/rust.toml
```

Alternative forms:

```
code-parser parse file.py -g grammars/python.toml
```

Parsing repositories:

```
code-parser parse-repo ./repo --grammar-dir grammars/
```

---

# Parsing Philosophy

This parser performs **structural parsing**, not full syntax parsing.

Focus is on identifying structural elements:

```
function
class
call
import
block
comment
```

The parser avoids complex grammars and ambiguous syntax rules.

Benefits:

* extremely fast
* robust to syntax errors
* suitable for large repositories

---

# Tokenizer

The tokenizer reads characters and produces tokens.

Token types:

```
identifier
keyword
string
comment
symbol
newline
```

Example token structure:

```zig
const Token = struct {
    kind: TokenKind,
    start: usize,
    end: usize,
};
```

TokenKind enum:

```zig
const TokenKind = enum {
    identifier,
    keyword,
    string,
    comment,
    symbol,
};
```

Tokens use **slice indices instead of string allocations**.

---

# Grammar Files

Grammars are provided externally.

Example (TOML):

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

[[patterns]]
type = "class"
sequence = ["class", "identifier"]

[[patterns]]
type = "import"
sequence = ["import", "identifier"]
```

Grammar describes **token sequences that trigger events**.

---

# Grammar Runtime Structures

Example Zig structures:

```zig
const Grammar = struct {
    patterns: []Pattern,
};
```

Pattern:

```zig
const Pattern = struct {
    kind: EventKind,
    sequence: []TokenPattern,
};
```

TokenPattern:

```zig
const TokenPattern = union(enum) {
    keyword: []const u8,
    identifier,
    symbol: u8,
};
```

---

# Grammar Compilation

Instead of matching patterns repeatedly, grammars are compiled into a **deterministic automaton**.

This converts pattern lists into a **state machine**.

Example pattern:

```
"fn" IDENTIFIER "("
```

State machine:

```
START
  │
  fn
  ▼
STATE1
  │
  IDENTIFIER
  ▼
STATE2
  │
  "("
  ▼
MATCH → emit FUNCTION event
```

This enables **linear-time parsing**.

---

# Automaton Data Structures

Example structures:

```zig
const State = struct {
    transitions: []Transition,
    event: ?EventKind,
};
```

Transition:

```zig
const Transition = struct {
    token: TokenPattern,
    next_state: usize,
};
```

Automaton:

```zig
const Automaton = struct {
    states: []State,
};
```

State `0` is the root.

---

# Automaton Builder

Patterns are compiled into a **prefix tree (trie)**.

Algorithm:

```
for each pattern
    start at root
    for each token
        create transition if missing
    mark final state with event
```

Pseudo-code:

```zig
fn addPattern(auto: *Automaton, pattern: Pattern) void {
    var state = 0;

    for (pattern.sequence) |token| {
        state = findOrCreateTransition(state, token);
    }

    auto.states[state].event = pattern.event;
}
```

---

# Parser Engine

Parser processes tokens sequentially.

Core loop:

```zig
state = 0

for token in tokens {
    if transition exists {
        state = next_state
    } else {
        state = 0
    }

    if state has event {
        emit event
    }
}
```

Time complexity:

```
O(n)
```

---

# Identifier Capture

Patterns may capture identifiers.

Example grammar DSL:

```
pattern function:
    "fn" $name:IDENTIFIER "("
```

This captures the function name.

Capture structure:

```zig
const Capture = struct {
    name: []const u8,
    position: usize,
};
```

---

# Block Detection

Blocks define structure boundaries.

Examples:

```
{ }
indentation
```

Parser maintains block stack:

```zig
const Block = struct {
    kind: BlockKind,
    start: usize,
};
```

Used for determining:

```
function boundaries
class bodies
nested structures
```

---

# Streaming Parsing

Parser works in a streaming pipeline.

```
reader → tokenizer → automaton → events
```

Benefits:

* supports very large files
* low memory usage
* minimal allocations

---

# Memory Strategy

Use Zig arena allocator:

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();

const allocator = arena.allocator();
```

Advantages:

* fast allocations
* cheap deallocation
* ideal for parsing workloads

---

# Parallel Parsing

Repository parsing can be parallelized.

Workflow:

```
list files
spawn worker threads
each worker parses file
```

Example Zig usage:

```zig
std.Thread.spawn(...)
```

---

# Output Format

Parser emits structured events.

Example JSON:

```json
{
  "events": [
    {
      "type": "function",
      "name": "login",
      "start": 120,
      "end": 240
    },
    {
      "type": "call",
      "name": "validate",
      "pos": 180
    }
  ]
}
```

These events are suitable for:

* code indexing
* embedding generation
* call graph construction
* AI agent queries

---

# Integration with MCP

Typical workflow:

```
AI Agent
   │
   ▼
MCP Server
   │
   ▼
code-parser CLI
```

Example command executed by MCP:

```
code-parser parse auth.rs --grammar grammars/rust.toml
```

The MCP server consumes JSON output and builds:

* embeddings
* vector index
* code navigation graph

---

# Performance Characteristics

Key properties:

```
O(n) parsing
minimal allocations
streaming pipeline
runtime grammars
```

Expected performance:

* millions of lines parsed in seconds
* low memory footprint
* suitable for large repositories

---

# Design Rules

Keep grammars **structural**, not syntactic.

Avoid:

```
complete language grammars
full AST construction
```

Focus on:

```
function detection
class detection
call detection
imports
blocks
```

---

# Development Roadmap

Phase 1:

```
CLI
file reader
tokenizer
JSON output
```

Phase 2:

```
grammar loader
automaton builder
pattern matching
```

Phase 3:

```
identifier capture
block detection
multi-language support
```

Phase 4:

```
parallel repository parsing
embedding chunk generation
MCP integration
```

---

# Future Extensions

Possible enhancements:

```
call graph generation
dependency graph
doc comment extraction
incremental parsing
structural queries
```

These features would support advanced AI code intelligence systems.

---

# Summary

This project implements a **fast structural code parser** designed for AI tooling.

Core ideas:

```
external grammars
automaton-based pattern matching
streaming token processing
event-based output
```

The result is a **simple, fast, extensible parser** suitable for indexing and understanding large codebases.


# Grammar DSL Specification

This section describes the **Grammar DSL** used by the lightweight parser.
The DSL defines **structural patterns** that the parser detects in source code.

Unlike full programming language grammars, this DSL focuses on **structural elements**, enabling fast and robust parsing.

The DSL is designed to be:

* simple to write
* easy to parse
* expressive enough for most programming languages
* stable for AI tooling

---

# Design Principles

The grammar system follows several important rules.

1. **Structure over syntax**

The grammar should describe **code structure**, not the entire language syntax.

Examples:

* function definitions
* class declarations
* imports
* calls
* blocks

Avoid attempting to replicate full language grammars.

---

2. **Token-based matching**

Patterns operate on **token sequences**, not characters.

Example:

```
"fn" IDENTIFIER "("
```

---

3. **Deterministic patterns**

Patterns compile into a **deterministic automaton** for fast matching.

The parser does not perform backtracking.

---

# Grammar File Structure

A grammar file consists of several sections:

```
language
keywords
patterns
blocks
```

Example:

```
language rust

keyword function: fn
keyword struct: struct
keyword import: use

pattern function:
    "fn" $name:IDENTIFIER "("

pattern struct:
    "struct" $name:IDENTIFIER

pattern call:
    $callee:IDENTIFIER "("

pattern import:
    "use" $module:IDENTIFIER
```

---

# Language Declaration

Defines the name of the language.

```
language rust
```

This value is informational but useful for tooling.

---

# Keywords

Keywords define reserved words used in patterns.

Example:

```
keyword function: fn
keyword class: class
keyword import: import
```

Internally these are added to the tokenizer keyword table.

---

# Patterns

Patterns are the **core of the grammar**.

Each pattern describes a sequence of tokens that trigger an event.

General syntax:

```
pattern <event-name>:
    <token sequence>
```

Example:

```
pattern function:
    "fn" IDENTIFIER "("
```

When this sequence appears, the parser emits a **function event**.

---

# Token Types

Patterns may reference the following token types.

## Keyword

Keywords are written using quotes.

```
"fn"
"class"
"import"
```

---

## Identifier

Matches any identifier token.

```
IDENTIFIER
```

Examples matched:

```
login
get_user
validate_token
```

---

## Symbols

Symbols represent punctuation characters.

Examples:

```
"("
")"
"{"
"}"
"."
","
```

---

## Literals

Future versions may support literals such as:

```
STRING
NUMBER
```

These are optional.

---

# Captures

Captures allow patterns to extract values from tokens.

Syntax:

```
$name:IDENTIFIER
```

Example:

```
pattern function:
    "fn" $name:IDENTIFIER "("
```

If the parser encounters:

```
fn login(
```

It produces:

```
name = "login"
```

---

# Multiple Captures

Patterns may capture multiple values.

Example:

```
pattern method_call:
    $object:IDENTIFIER "." $method:IDENTIFIER "("
```

Example code:

```
user.login()
```

Captured values:

```
object = user
method = login
```

---

# Optional Tokens (Future)

Future versions may allow optional tokens.

Example:

```
pattern import:
    "from" IDENTIFIER "import" IDENTIFIER
```

Optional tokens could be expressed as:

```
IDENTIFIER?
```

This feature may be added later.

---

# Repeating Tokens (Future)

Some patterns might allow repetition.

Example:

```
IDENTIFIER+
```

Example use case:

```
module.submodule.function()
```

---

# Block Definitions

Blocks describe structural scopes.

Example:

```
block open: "{"
block close: "}"
```

This allows the parser to detect:

* function bodies
* class bodies
* nested blocks

---

# Indentation-Based Blocks

Some languages use indentation instead of braces.

Example:

```
block indentation: true
```

This enables parsing for languages like:

* Python
* YAML-like structures

---

# Event Types

Events correspond to pattern names.

Example:

```
pattern function:
pattern class:
pattern call:
pattern import:
```

These generate events:

```
function
class
call
import
```

---

# Event Output Example

Input code:

```
fn login(user) {
    validate(user)
}
```

Generated events:

```
function name=login
call callee=validate
```

In JSON form:

```
{
  "events": [
    {
      "type": "function",
      "name": "login",
      "start": 0
    },
    {
      "type": "call",
      "callee": "validate",
      "pos": 20
    }
  ]
}
```

---

# Pattern Compilation

During startup the parser:

1. loads grammar file
2. parses DSL
3. converts patterns to token sequences
4. builds a deterministic automaton

Compilation pipeline:

```
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

The automaton is reused for all files.

---

# Pattern Automaton Example

Pattern:

```
"fn" IDENTIFIER "("
```

Automaton:

```
START
  │
  fn
  ▼
STATE1
  │
  IDENTIFIER
  ▼
STATE2
  │
  "("
  ▼
MATCH → emit function
```

---

# Matching Rules

The parser processes tokens sequentially.

For each token:

```
read token
follow transition
if final state reached
    emit event
```

This guarantees **linear parsing time**.

---

# Best Practices for Grammar Authors

To ensure good performance and reliability:

### Keep patterns short

Good:

```
"fn" IDENTIFIER "("
```

Bad:

```
"fn" IDENTIFIER "(" IDENTIFIER "," IDENTIFIER ")"
```

---

### Prefer structural triggers

Use tokens that clearly indicate structure.

Examples:

```
fn
class
def
import
```

---

### Avoid ambiguous patterns

Example of ambiguous pattern:

```
IDENTIFIER IDENTIFIER
```

This can appear in many contexts.

---

# Example Grammars

## Rust

```
language rust

keyword function: fn
keyword struct: struct
keyword import: use

pattern function:
    "fn" $name:IDENTIFIER "("

pattern struct:
    "struct" $name:IDENTIFIER

pattern call:
    $callee:IDENTIFIER "("

pattern import:
    "use" $module:IDENTIFIER
```

---

## Python

```
language python

keyword function: def
keyword class: class
keyword import: import

pattern function:
    "def" $name:IDENTIFIER "("

pattern class:
    "class" $name:IDENTIFIER

pattern call:
    $callee:IDENTIFIER "("

pattern import:
    "import" $module:IDENTIFIER
```

---

# Grammar Directory Layout

Recommended project structure:

```
grammars/
 ├─ rust.grammar
 ├─ python.grammar
 ├─ javascript.grammar
 └─ go.grammar
```

The parser selects grammars based on file extension.

---

# Grammar Evolution

Future DSL extensions may include:

```
optional tokens
repeating tokens
named blocks
query patterns
```

However the core philosophy remains:

```
keep grammar simple
keep parser deterministic
```

---

# Summary

The Grammar DSL provides a simple way to define **structural code patterns**.

Key properties:

```
runtime grammar loading
deterministic pattern matching
identifier capture
fast automaton execution
```

This approach enables the parser to support **many programming languages** without embedding language logic inside the binary.




Probabilistic Parsing
Motivation

A lightweight structural parser relies on simple patterns and structural rules.
However, when parsing unknown languages, incomplete code, or ambiguous constructs, deterministic rules may not always produce correct results.

A probabilistic parser extends the structural parser by assigning confidence scores to detected structures instead of making strict binary decisions.

This approach allows the system to:

tolerate incomplete syntax

handle unknown language constructs

detect structures with partial evidence

rank multiple possible interpretations

Rather than asking “Is this definitely a function?”, the parser asks:

“How likely is this structure to represent a function?”

Core Idea

Instead of rules producing true / false, they produce a probability score.

Example detection:

foo(a,b)

Possible interpretations:

Structure	Probability
Function call	0.92
Macro invocation	0.05
Tuple construction	0.03

The parser keeps the highest probability interpretation.

Rule Scoring

Each parsing rule contributes a score based on matched evidence.

Example rule:

(keyword)? identifier "(" args ")" block

Evidence weights:

Feature	Weight
function keyword	+0.5
identifier	+0.2
parentheses	+0.2
block	+0.3

Example code:

def add(a,b):

Score:

keyword match: +0.5
identifier: +0.2
args: +0.2
block: +0.3

total = 1.2
normalized ≈ 0.95

This produces:

Function(name="add", confidence=0.95)
Probabilistic Pattern Matching

Multiple rules may match the same code fragment.

Example code:

foo(bar)

Possible interpretations:

Rule	Score
Function call	0.88
Constructor call	0.40
Macro invocation	0.22

The parser selects the highest score but may also keep alternatives.

Scoring Sources

Probabilities can be derived from multiple signals:

Structural Evidence

Detected syntax elements:

parentheses

blocks

indentation

assignment operators

Keyword Matching

Example:

def
fn
function

These increase probability that the structure is a function definition.

Context

Example:

router.get("/users")

Inside a web framework context:

endpoint_probability = 0.9

Without context:

method_call_probability = 0.6
Frequency in Repository

Patterns appearing frequently gain higher confidence.

Example repository pattern:

router.get(...)
router.post(...)
router.put(...)

The system learns that these patterns represent HTTP routes.

Confidence Thresholds

Rules can define thresholds.

Example:

Confidence	Interpretation

0.8 | Strong match |
0.5 – 0.8 | Probable match |
0.3 – 0.5 | Weak match |
< 0.3 | Ignored |

Example output:

{
  "type": "FunctionCall",
  "name": "foo",
  "confidence": 0.91
}
Integration with the Structural Parser

The probabilistic parser sits on top of the structural parsing layer.

Pipeline:

source code
   ↓
tokenizer
   ↓
structural index
   ↓
deterministic pattern matcher
   ↓
probabilistic scoring
   ↓
ranked AST nodes

The structural parser finds candidate structures, and the probabilistic layer ranks them.

Handling Incomplete Code

Probabilistic parsing is particularly useful for incomplete fragments.

Example:

fn add(a,b

Evidence:

Feature	Score
keyword	+0.5
identifier	+0.2
parenthesis start	+0.2

Result:

Function(name="add", confidence=0.65)

Even though the syntax is incomplete.

Example Output

Example parsed structure:

{
  "type": "Function",
  "name": "add",
  "args": ["a","b"],
  "confidence": 0.94,
  "children": [
    {
      "type": "Call",
      "name": "sum",
      "confidence": 0.87
    }
  ]
}
Advantages

Probabilistic parsing provides several benefits:

Robustness

Works with:

broken syntax

partial code

generated fragments

Language Flexibility

Handles:

unknown programming languages

domain-specific languages

mixed-language files

Better AI Integration

Confidence scores allow AI agents to:

choose the most likely interpretation

request deeper analysis when confidence is low

combine multiple hypotheses

Future Extensions

Possible enhancements include:

learning rule weights from repositories

repository-specific syntax adaptation

LLM-assisted rule generation

framework pattern recognition

Summary

The probabilistic parser enhances structural parsing by introducing confidence-based interpretation.

Instead of strict rule matching, the parser evaluates how likely a structure is, enabling reliable parsing of:

incomplete code

unfamiliar languages

ambiguous syntax

This approach makes the system particularly suitable for AI agents and automated code analysis systems, where flexibility and resilience are more important than strict compiler-level correctness.

