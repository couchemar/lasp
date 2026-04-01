# LASP Feedback Collection Guide for Coding Agents

## Purpose

When using LASP during development (dogfooding), collect structured feedback to drive improvements. This doc describes what to look for and how to record it.

## What to Record

### False positives

A pattern matched something it shouldn't have. Example: a `call` pattern matching inside a string literal, or a `function` pattern matching a type annotation.

Record:
- The source file and line
- The grammar used
- The event JSON that was wrong
- What the correct behavior should be

### False negatives

A structural construct exists in the source but LASP didn't detect it.

Record:
- The source file and line
- The grammar used
- What construct was missed
- The raw token stream around that location (run without grammar)

### Unexpected token kinds

The tokenizer classified a character sequence as the wrong kind.

Record:
- The source text
- The token kind LASP assigned
- The expected token kind

### Missing features

Something you needed but LASP doesn't support yet.

Record:
- What you were trying to do
- What grammar construct or CLI flag would have helped

### Performance observations

Parsing took noticeably long or used unexpected memory.

Record:
- File size and language
- Grammar complexity (number of patterns)
- Approximate time or any observable delay

## How to Collect

### Quick inline notes

When you notice something during a task, save it to memory:

```
mcp_memory_create_entities([{
  name: "LASP Feedback: <short description>",
  entityType: "feedback",
  observations: [
    "Type: false-positive|false-negative|wrong-token|missing-feature|performance",
    "File: <path>",
    "Grammar: <grammar path or none>",
    "Details: <what happened vs what should happen>",
    "Date: <current date>"
  ]
}])
```

### Comparison runs

When working on LASP changes, compare before/after:

```bash
# Stable output
.bin/lasp parse <file> -g <grammar> > /tmp/stable.json

# Development output
zig-out/bin/lasp parse <file> -g <grammar> > /tmp/dev.json

# Diff
diff /tmp/stable.json /tmp/dev.json
```

If the diff shows regressions, record them as feedback entities.

### Batch review

Periodically search memory for accumulated feedback:

```
mcp_memory_search_nodes({ query: "LASP Feedback" })
```

Group related items and propose improvements or file them as spec tasks.

## Feedback Categories

| Category | Priority | Action |
|----------|----------|--------|
| False positive | High | Add exclusion pattern or position constraint to grammar |
| False negative | High | Add or adjust pattern in grammar |
| Wrong token kind | Medium | Fix tokenizer classification logic |
| Missing feature | Low | Add to TODO.md roadmap |
| Performance | Low | Profile and optimize if measurable |

## Turning Feedback into Action

1. Search memory for feedback entities related to the current work
2. Group by category and affected component
3. For grammar issues: update the grammar file and re-test
4. For tokenizer/engine issues: create a spec task or fix directly
5. After addressing feedback, delete or update the memory entity
