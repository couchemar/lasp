# LASP Feedback Collection Guide

## Purpose

When using LASP on a project, collect structured feedback so the LASP developers can improve it. This doc describes what to look for and how to record it.

## What to Record

### False positives

A pattern matched something it shouldn't have.

Record: the source file and line, the grammar used, the event JSON that was wrong, what the correct behavior should be.

### False negatives

A structural construct exists in the source but LASP didn't detect it.

Record: the source file and line, the grammar used, what construct was missed, the raw token stream around that location (run without `--grammar`).

### Unexpected token kinds

The tokenizer classified a character sequence as the wrong kind.

Record: the source text, the token kind LASP assigned, the expected token kind.

### Missing features

Something you needed but LASP doesn't support yet.

Record: what you were trying to do, what grammar construct or CLI flag would have helped.

## How to Record

Save feedback to memory so LASP developers can review it later:

```
mcp_memory_create_entities([{
  name: "LASP Feedback: <short description>",
  entityType: "feedback",
  observations: [
    "Type: false-positive|false-negative|wrong-token|missing-feature",
    "File: <path>",
    "Grammar: <grammar path or none>",
    "Details: <what happened vs what should happen>",
    "Date: <current date>"
  ]
}])
```

## Reviewing Accumulated Feedback

Search memory periodically:

```
mcp_memory_search_nodes({ query: "LASP Feedback" })
```

Group related items and report them to the LASP project maintainer.
