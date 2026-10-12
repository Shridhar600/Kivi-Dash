# Contributing

## Build and test

```bash
swift test                              # the test suite
swift build -c release                  # release build
swift format lint -r Sources --strict   # lint (must be clean)
./build.sh                              # assemble and sign Kivi-Dash.app
```

Requires macOS 14+ and a Swift 6 toolchain. There are no external package
dependencies, by design: this app reads your data directory, and the dependency
count is kept at zero so the code stays auditable.

## Architecture

- `Sources/KiviCore` — all logic: the SQLite wrapper, snapshot, extraction,
  ingest and metric queries. It is a library target with no UI code.
- `Sources/KiviStatsApp` — SwiftUI only. It reads precomputed rollups through
  `StatsQuery` and never recomputes an aggregate.
- `Tests/KiviCoreTests` — the whole test suite. Nothing in `Sources/` has tests
  beside it.
Rules worth keeping:

- Keep SQLite calls inside `KiviCore/Support/SQLite.swift`. If you need new C API,
  expose it there rather than importing `SQLite3` elsewhere.
- Use the parameterised `query(_:bindings:_:)` / `execute(_:bindings:)` overloads
  whenever there are `?` placeholders. **An unbound parameter is silently NULL**,
  which turns a typo into a query that quietly returns nothing.
- Never open Kivi's store for writing, and never use `immutable=1` on it. Both are
  silent-wrong-answer failure modes.
- Transcript text must never enter a type that could be persisted. `ExtractedTake`
  has no text field on purpose — that is a compiler-enforced privacy boundary, not a
  convention. `SchemaTests` also fails if a text-capable column is ever added.

## Adding a metric

1. Decide the definition precisely, including which rows are excluded and why.
2. If it can be derived from the facts table, compute it in `StatsQuery` from
   `daily_rollup` — do not add a rollup table unless the metric cannot be summed.
   Medians in particular do not decompose, so never store a daily median.
3. Add a test with numbers you worked out by hand. Prefer a test that fails loudly
   under the plausible wrong implementation (e.g. mean-of-ratios versus
   ratio-of-sums for WPM).

## Reporting a problem

If Kivi changes its schema, this app refuses to write rather than recording zeros,
and the menu bar icon turns red. Please include the app version, the Kivi version, and the
line shown in the popover's footer — it carries the reason the run failed, which is
usually enough to tell a schema drift from a missing store.
