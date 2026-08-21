# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-08-21

### Added

- Tokenizer emitting structural tokens (keyword, identifier, string, comment, symbol, ...) as JSON with byte offsets, line, and column.
- TOML grammar files defining keywords, patterns, blocks, and confidence weights; example grammars for Zig and Erlang.
- Pattern compilation into a deterministic prefix-trie automaton with linear-time streaming matching (no backtracking).
- Identifier captures (`$name:IDENTIFIER`), exact identifier matching (`Config:IDENTIFIER`), and position-constrained patterns (`position = "start"`).
- Unified constraint system (`[[patterns.constraints]]`) with depth-based filtering on capture values and lookback windows.
- Probabilistic confidence scoring with relaxed matching, optional elements, competing patterns, and configurable weights.
- Block boundary tracking (`block_start`) and line numbers on emitted structural events.
- `lasp parse` command accepting file paths or stdin (`-`), with `--node`/`-n` node-type filtering and `--names-only` plain-text output.
- `lasp parse-dir` command for directory parsing with `--grammar-dir`.
- `lasp query` command with CSS-selector-inspired structural queries (type selectors, attribute conditions, confidence thresholds, wildcards).
- `--version` / `-V` / `version` reporting the binary version; version is sourced from `build.zig.zon` (semver) and embedded at build time.

