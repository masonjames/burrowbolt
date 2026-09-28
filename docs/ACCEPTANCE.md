# Acceptance ledger

Implementation is available in the draft BurrowBolt PR. It is **not release accepted**.

## Verified implementation checks

- Reviewed performance baseline: BlitzTree `699fd919d58cbb6b33055d5404890071c6b9c070`. The application history now also includes upstream v0.5.5 (`d68ff95f`), retaining BurrowBolt automatic planning. Mole remains the pristine `50790e8a` subtree.
- Engine: 16 passed, one benchmark ignored. Worker protocol: 5 passed. CLI: 20 passed. Adapter: 8 passed, including exact selected paths, active targets, unknown process visibility, namespace separation, and tolerated upstream no-match statuses.
- Installed Codex isolation: 26 configured MCP servers reported disabled and zero exposed tools before any model turn. An offline protocol check refuses connected/unknown tools. Claude is launched with no built-in or MCP tools. Live model-output acceptance remains separate.
- Native insights: cache signatures, project pruning, installer/ZIP distinction, old Downloads, lossy path refusal, largest-files cap, and search cap pass.
- UI/agent algorithm harnesses: outline/cleanup parity, prompt/parser parity, cancellation, retained failures and one-shot automatic planning pass. These are not desktop interaction tests.
- Renderer: 28 pixel/geometry comparisons, 126 cushion checks, 2,000 fractional checks, 260,708 ring hits and 11,344 treemap hits passed. The baseline fixture's missing `Tree.drawn` contract is repaired.
- Mole: all 598 patched safeguard tests passed with exit 0. One upstream Mail fixture is isolated from the real running Mail app; production guards are unchanged by that test-only patch.
- Native Foundation Trash moved only a uniquely created fixture, preserved its sibling, and removed only its own receipt in an earlier backend smoke check. After tightening complete-process visibility, this Mac's unprivileged probe cannot establish that visibility; current production cleanup must refuse rather than bypass it. Deterministic worker tests and isolated adapter tests do not waive that limitation.

## Performance evidence

- Nine alternating `/Applications` scan pairs: 983,837 files / 130,319 directories, identical allocated bytes and error totals. Median baseline 1.51349 seconds; candidate 1.51103 seconds. Median peak footprint 69.19 / 68.78 MB. Raw local evidence: `build/perf-results/burrowbolt-applications.json`.
- Five offscreen Retina first-map pairs: 1,114,157 nodes, identical bytes/scale. Medians 1.55447 / 1.56064 seconds; longest main-loop-gap medians 34.10 / 24.36 ms. This endpoint excludes visible-window paint. Evidence: `build/first-map-comparison.txt`.
- Retina rendering: balanced 3.024 / 2.973 ms, wide 6.255 / 5.943 ms, deep 2.017 / 2.053 ms. Ring and hit-test cases remained comparable. These observations do not prove all-machine or all-storage acceptance.
- An initial 16.4-million-node home profile exposed family-caller/deadline incompatibilities. Those were corrected and tested. A subsequent unlimited ZIP-listing run exceeded 390 seconds; automatic ZIP listing now has a shared 20-second budget and selected-file inspection remains available. Keep these failed runs as evidence, not passing measurements.

## Required before public release

- [ ] No repeatable scan, first-map or rendering regression across required paired workloads, including external storage; 5% triggers investigation rather than permission to regress.
- [x] Bounded enrichment measured on 16,401,536 nodes: 171.65 seconds, 26,603 findings, 846 navigation requests, maximum main-loop gap 46.81 ms. Aggregate sampled RSS peaked at 2.391 GB across app/worker/probe descendants (shared pages may be counted multiple times; this is not unique memory). Five family probes were unavailable and 5,985 archive listings were deferred. This is an honest partial result, not complete family acceptance. Raw evidence: `build/enrichment-profile.txt` and `build/enrichment-memory.json`.
- [ ] Representative family coverage and complete process evidence verified on supported desktop configurations; unsupported owner commands and container-stub actions remain informational.
- [ ] GUI behavior verified, including selection, keyboard access, stale render discard, cleanup cancellation and update deferral. A fixture app rendered 13 nodes, but the desktop inspection tool hung before returning an accessibility tree or screenshot.
- [ ] Fresh-machine installation, offline operation and Full Disk Access onboarding verified without developer tools.
- [ ] Minimum macOS 14 tested on a real machine or VM.
- [ ] Signed/notarized app and DMG assessed successfully.
- [ ] Real older-to-newer Sparkle update and tampered-update rejection verified.
- [ ] Reviewed draft release published; unchanged signed appcast served over HTTPS.

A Developer ID Application identity is available in Keychain. The BurrowBolt Sparkle key is also in Keychain; only its public key is tracked. The `burrowbolt-notary` notarization profile was not present at preflight. GitHub Pages is configured for workflow deployment; no update feed has been published. Development installers are explicitly unnotarized and disable in-app updates.

## Installer and hosted evidence

The development `BurrowBolt.dmg` and its embedded app have Developer ID signatures, verified after a read-only mount. The bundle contains the worker, Mole resources, Sparkle, notices and the Applications shortcut, targets arm64/macOS 14, and disables update polling. It is **not notarized** and is not a public release.

Sparkle 2.10.0 generated and verified the local DMG signature and signed feed; altered DMG and feed copies were rejected by its official verifier. This is cryptographic verification, not an older-to-newer installation test. Corresponding source packaging was exercised, including vendored Rust dependencies and pinned Sparkle sources; offline Cargo metadata resolved the vendored dependencies.

Local full validation passed on app-source commit `398481c8`. Hosted full checks, performance and Mole safeguards passed on `5fb67cce` (run `36361657783`). Other hosted runs flagged different timing cases: an 18% first-map increase did not repeat, while the expanded run improved first-map time and flagged scan/other renderer cases. The CI gate now retains three fixed rounds, each with 21 scan/first-map pairs, and blocks cases above 5% in at least two rounds. Isolated spikes remain visible for review; this does not waive smaller repeatable regressions or the broader release-performance checklist.
