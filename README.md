# BurrowBolt

**BlitzTree’s speed, Mole’s digging.** A native disk explorer for Apple Silicon Macs running macOS 14 or later.

BurrowBolt retains BlitzTree’s Rust bulk scanner and Swift/AppKit treemap, and bundles pinned Mole rules for disk insights and selected cleanup. It shows allocated bytes, keeps incomplete scans visible, and defaults removals to Trash. A Claude or Codex agent can automatically propose a plan after the first map; the app validates actions and requires approval before cleanup. Planning sends candidate paths and measured sizes to your selected agent provider. Built-in command/file tools and MCP integrations are disabled for this planning session; incompatible agent versions fail closed.

This is the initial development implementation. A signed public installer is not yet released. See [acceptance status](docs/ACCEPTANCE.md) for the distinction between implemented behavior and release validation.

## Build

Use an Apple Silicon Mac with Xcode 27 / Swift 6.4, Rust 1.98.1, Python 3, and Git. Exact upstreams and framework checksums are in [`UPSTREAMS.lock`](UPSTREAMS.lock).

```sh
./build.sh
BURROWBOLT_QA_NO_AGENT=1 build/BurrowBolt.app/Contents/MacOS/BurrowBolt /path/to/folder
scripts/validate.sh
scripts/package-development.sh
```

The build downloads and verifies Sparkle 2.10.0, stages Mole with strictly applied patches, embeds the worker and all runtime resources, and signs locally with an ad-hoc identity. The resulting app does not require Homebrew, Python, Rust, Go, Mole, or an AI agent on the destination Mac. Developer tools used by optional cleanup rules remain optional.

A development DMG is written to `dist/development/BurrowBolt.dmg`; it is **not notarized**. Public release builds require Developer ID, notarization, and update-signing credentials. [Release instructions](docs/RELEASING.md).

## Using it

Choose a folder or scan the data volume. Full Disk Access improves coverage; it does not grant privileged cleanup. Select a tile, double-click a folder to zoom, and use Escape, Left Arrow, Delete, or Command-Up to return to its parent. Return zooms into the selected folder. The native outline provides keyboard and accessibility navigation.

Search filters names, or paths when the query includes `/`; the treemap highlights matches without rearranging its tiles. “Largest Files” browses the current inventory. Select a finding to see its explanation, size semantics, and blocking reason. An informational finding is never permission to remove data.

Cleanup rechecks the current candidate and its file identities through Mole’s guards. It can refuse an earlier proposal if an app becomes active or a file changes. Trash is recoverable until separately emptied. BurrowBolt can permanently remove only items for which its current worker holds a successful Trash receipt.

Settings belong to `com.masonjames.burrowbolt`. Mole configuration, logs and cache are redirected only in the app’s staged copy, under BurrowBolt’s directories. Existing Mole settings and `HOME` are unchanged.

No usage analytics or automatic crash reporting is included. Logs stay local; matching crash symbols ship as a separate build artifact. [Diagnostics and telemetry](docs/DIAGNOSTICS.md).

## Maintaining the fork

BlitzTree’s source layout, Git history, and internal Rust crate name are retained to reduce merge conflicts. Mole is a pristine squashed subtree in `vendor/mole`; integration patches are outside it. [Maintenance and capability matrix](docs/MAINTENANCE.md).

The weekly workflow proposes separate draft PRs for upstream updates. It never merges them. Review new cleanup coverage and rerun correctness, safety, rendering, and paired performance gates before accepting an update.

## License

The combined application is distributed under GPLv3. BlitzTree’s MIT notice is preserved in `LICENSES/BlitzTree-MIT.txt`, Mole’s notice remains in its subtree, and bundled dependencies include their licenses. Release packaging includes corresponding source and locked Rust dependency source.
