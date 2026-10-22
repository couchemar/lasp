# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-10-23

### Added

- Operator tokens are now matchable in pattern sequences (unified punctuation matching). A quoted punctuation literal matches operator tokens (`+ - * / = < > ! & ^ % ~` and `|`) in addition to symbol and delimiter tokens, keyed on exact text, so sigil constructs can be anchored on their leading operator — e.g. `sequence = ["-", "module", "("]` for Erlang `-module(...)`, or `@`/`&`/`?` for attributes, capture refs, and macros. Single-character only: a multi-character literal like `"->"` compiles but never matches the single-character-operator tokenizer. A `-module` demonstration pattern was added to the example Erlang grammar. (Issue #19)
- Same-type pattern union: multiple `[[patterns]]` entries sharing one `type` act as alternatives of that type. Overlapping matches collapse to a single primary event per region (longest-match, then grammar order), and prefix alternatives defer to the longer form when it matches while still emitting the shorter when only it matches. No new grammar keys, flags, or JSON fields — union-by-type is an engine/observation property and works for any author-chosen `type` name.
- Opt-in `--alternatives` flag (parse only): every winning event gains an `alternatives` JSON array listing the losing competitors of the same region, each with only `type`, `confidence`, and captures (no position fields), ordered by the standard tiebreak. The winner keeps all its fields. Flag off ⇒ byte-identical output with no `alternatives` key. Rejected on `query` with a descriptive error; ignored by `--names-only`. Turns LASP into a probabilistic front-end for an LLM disambiguator.
- Optional per-pattern `prior` confidence multiplier: `final = clamp(evidence × prior, 0, 1)`, applied before the 0.3 filter and before competing-candidate selection. Range `(0.0, 2.0]`, default `1.0` (exact no-op). Lets grammar authors demote likely-false interpretations (soft-to-hard tuning via the 0.3 filter) or boost weak-but-likely matches without hard blacklists or new tiebreak logic. Out-of-range/non-numeric values are rejected at load time with a descriptive CLI error.
- Parameterized captures `$name:IDENTIFIER(sep="...", suffix="...")`: a `sep` separator greedily joins a multi-token path (`A.B.C`, `A::B::C`) and a `suffix` set absorbs one trailing character (`foo!`), with the captured value equal to the exact source span. Separator matching is source-byte adjacency, so it is independent of how the tokenizer splits the separator; confidence is counted once regardless of span length; bare `$name:IDENTIFIER` is unchanged. Separators and suffix sets are author-supplied — nothing language-specific is baked in. (Issue #22)
- `number` sequence-element primitive: matches exactly one numeric token (the numeric analogue of the `identifier` wildcard), supports the `?` optional suffix (`number?`), captures nothing, and scores with the symbol evidence weight. It composes with operator matching and same-type pattern unioning to express arity-qualified reference recipes such as `["&", "$callee:IDENTIFIER", "/?", "number?"]`. Purely additive — existing grammars and output are unchanged. (Issue #16)
- Configurable comment prefixes via a `[comments]` grammar section: `line` (array of 1–8-char line-comment prefixes, up to 16) and paired `block_open`/`block_close` delimiters. The tokenizer uses these at runtime instead of hardcoded `//`/`#`/`/* */`, so any language's comment syntax (e.g. Erlang `%`, Lua `--`, Haskell `{- -}`) can be declared without recompiling. Grammars with no `[comments]` section keep the default C-style behavior byte-for-byte. `formatGrammar` round-trips the section. (Issues #9, #18)
- `[comments] line = ["%"]` added to the example Erlang grammar.

### Fixed

- Patterns that share an identical token sequence no longer shadow each other. Previously, when two patterns compiled to the same terminal trie state (e.g. `function` with `position = "start"` and `call`, both matching `["$IDENT", "("]`), only the last one declared emitted — so `--node function` could return zero matches. The compiler now keeps every colliding pattern's event on the shared terminal state in grammar order, and the engine evaluates each as a competing candidate, so `position` and depth constraints route each match to the right pattern type. (Issue #17)
- Erlang (and any `%`-comment language): an apostrophe inside a line comment no longer opens a spurious string literal that swallows all following code. Comment recognition now runs before string tokenization, so quote characters in comments stay comment content. Regression guard: all top-level function heads in a fixture with apostrophe-bearing `%%` comments are detected (6/6, previously 0/6). (Issues #9, #18)
- Tokenizer integer overflow when computing the column of a multi-line block comment: the emitted token's `col`/`line` now reflect where the comment started, not where it ended.
- `--names-only` output no longer emits a spurious trailing blank line. The unconditional end-of-main newline is now guarded on `!parsed.names_only`, fixing the off-by-one `wc -l` vs `grep -c .` mismatch and making zero-match names-only output exactly 0 bytes. (Issue #21)

## [0.2.0] - 2026-08-21

### Changed

- Migrated to Zig 0.16.0: filesystem access via the new `std.Io` API (`Dir.cwd().openFile(io, ...)`, `File.stdout().writer(io, ...)`), child-process tests via `std.process.run`/`spawn`, string building via `std.Io.Writer.Allocating`.
- Upgraded `minish` dependency 0.1.0 → 0.3.0 (Zig 0.16-native, no transitive dependencies).

### Fixed

- Pinned all Zig package dependencies to immutable commit archives instead of moving branch URLs; fresh fetches now verify hashes reproducibly.

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

