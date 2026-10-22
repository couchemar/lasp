# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this project is

LASP is a language-agnostic structural parser CLI ("jq for code structure"). It detects functions, calls, structs, enums, and blocks via universal token patterns compiled into a deterministic automaton, emitting JSON events or filtered query results. Grammars are TOML files — no recompile needed for new languages.

**Dogfood rule: use LASP while developing LASP.** The fastest way to understand, verify, and improve this codebase is through its own CLI.

## Build & Test

```bash
nix develop          # dev shell (Zig 0.16.0)
zig build            # binary at zig-out/bin/lasp
zig build test       # ALL tests (405) — bare `zig test src/*.zig` does NOT work
nix build            # ReleaseSafe build at ./result/bin/lasp
lasp --version       # semver, sourced from build.zig.zon
```

`.bin/lasp` is a prebuilt snapshot; after changing parser/grammar/query code, exercise the freshly built `zig-out/bin/lasp`, not the stale copy.

## Use LASP during development

Verified patterns (grammar: `examples/grammars/zig.toml`, `L` = that binary):

**Before editing a file — map its structure instead of reading it whole:**
```bash
$L parse src/parser/engine.zig -g examples/grammars/zig.toml --node function --names-only
```

**Find a definition (wildcard matches any node type):**
```bash
$L query '*[name="parseArgs"]' src/cli/args.zig -g examples/grammars/zig.toml --names-only
```

**Find all call sites of a function:**
```bash
$L query 'call[callee="formatCliError"]' src/main.zig -g examples/grammars/zig.toml --names-only
```

**Refactor safety net — diff structure before/after:**
```bash
$L parse src/foo.zig -g examples/grammars/zig.toml --node function --names-only > /tmp/before.txt
# ... edit ...
diff /tmp/before.txt <($L parse src/foo.zig -g examples/grammars/zig.toml --node function --names-only)
```

Node-type note: private fns emit as `function`, `pub fn` as `pub_function` — prefer `*` selectors when you don't care about the type. Confidence filtering (`[confidence>0.8]`) helps separate real matches from relaxed guesses.

**After changing tokenizer, engine, loader, compiler, or query modules:** don't stop at `zig build test`. Smoke-test observable behavior end-to-end:

```bash
echo 'fn add(a: i32, b: i32) i32 { return a + b; }' | $L parse - -g examples/grammars/zig.toml --node function --names-only   # expect: add
$L parse tests/fixtures/sample.erl -g examples/grammars/erlang.toml | head    # JSON events stream
```

**When adding grammar-DSL features** (captures, constraints, weights): extend `examples/grammars/*.toml` if applicable, then prove the feature with a real `parse`/`query` invocation, not just unit tests.

## Conventions

- Full CLI reference: [AGENT_USAGE.md](AGENT_USAGE.md); architecture: `.kiro/steering/`; specs: `.kiro/specs/`.
- Version releases: bump `version` in `build.zig.zon` + add a `CHANGELOG.md` section ([Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format, [semver](https://semver.org/spec/v2.0.0.html)).
- Dependencies are pinned to immutable commit archives in `build.zig.zon`; when updating one, find the commit whose tree hashes to the target package hash (`git archive <sha> | tar -x -C dir && zig fetch dir`) and re-verify with a clean `ZIG_GLOBAL_CACHE_DIR`.
