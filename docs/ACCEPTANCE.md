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

## Second review

The follow-up review fixed Data-volume alias mismatches in exclusion/root checks, bounded worker replies and preserved successful per-item receipts across process exit, rejected stale enrichment after a scan change, corrected overlapping fallback-plan totals, and removed concurrent mutation warnings from agent discovery. Active-file and unknown-process refusals now have different explanations; the underlying Mole guards remain intact. New regression checks cover both exclusion spellings, fragmented/oversized replies, invalid protocol versions, and exit immediately after a cleanup result.

Builds now preserve separate app/worker crash symbols with UUID and source-line validation, embed their source commit, and explicitly disable Sparkle system profiling. No Sentry/PostHog client or remote log upload has been added. See `DIAGNOSTICS.md` for what is retained locally and the proposed opt-in error-reporting integration.

These corrections do not close the outstanding signed/notarized release, complete cleanup-coverage, desktop, minimum-OS, or real-update acceptance checks above.

The worker checks also exercise a process that stays alive between requests, plus cancellation/refusal/recovery against the real bundled Rust helper. This caught a buffering stall in the initial stream-drain implementation; the reader now uses one POSIX pipe read per available chunk.

Hosted run `36373393366` flagged deep treemap hits at 0.042–0.044 ms versus 0.045–0.047 ms for only 1,000 points. The hot lookup source was unchanged. The harness now measures the same 50,000-point workload for both maps and retains six decimal places in milliseconds, instead of quantizing those tiny samples to whole microseconds. The 5%/three-round gate is unchanged. Three fixed local rendering rounds found no repeatable >5% cases; deep-hit ratios were 0.979, 0.991 and 0.993. Raw old hosted and new local measurements are retained under `build/review-ci-86a197f1` and `build/review-rendering-round*.txt`; hosted confirmation remains a separate gate.

Hosted run `36374313463` passed correctness and rendering checks but flagged first-map ratios of 0.996, 1.095 and 1.090; Mole's later CI stage was skipped, not passed. Investigation measured 4–9 ms between engine completion and the next 60 Hz progress poll on a local fixture. The app now receives an additive C completion callback, explicitly nonisolated at the Swift boundary, and dispatches completion to the main thread. Progress still polls at 60 Hz. A regression check verifies result publication and exactly one notification even when a cancelled handle is freed early. Three fixed local rounds of 21 pairs on 50,402 nodes measured first-map ratios of 0.863, 0.846 and 0.848 (about 74 ms baseline versus 62–63 ms candidate). Raw hosted failure and local results remain under `build/review-ci-final` and `build/review-completion-first-map-*.json`; this does not substitute for final hosted or broader workload acceptance.

Run `36375668086` on `577af272` passed full correctness and all three hosted performance rounds, with no >5% investigation signals. First-map ratios were 0.721, 0.639 and 0.600. Mole passed 597/598 checks; the inherited cumulative ZIP-budget test failed without reporting which assertion. Twelve fixed isolated runs passed with unchanged assertions, so the hosted cause is unconfirmed. The test-only patch now reports the specific failure; no safeguard, timeout or assertion was relaxed. The failed run is retained under `build/review-ci-577af272`.
