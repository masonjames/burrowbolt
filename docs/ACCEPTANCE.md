# Acceptance ledger

This ledger tracks evidence; implementation is not release acceptance.

- Reviewed baseline: BlitzTree `699fd919d58cbb6b33055d5404890071c6b9c070`; Mole `50790e8ac4b8346a071f9cc64356c7f86b7b142c`.
- Baseline `/Applications`: 983,837 files, 130,319 directories; warm alternating same-binary medians 1.519 / 1.530 seconds, approximately 68 MB peak footprint. Raw local records: `build/perf-results/baseline-applications.json`. These are baseline observations, not a performance acceptance claim.
- Rendering harness repaired: fixture now implements the production `Tree.drawn` contract. Pixel/geometry, cushion bands, fractional coverage and hit-testing comparisons pass against the reviewed baseline.
- Initial worker tests cover containment, replacement, symlink rejection, stale/cancelled generation, selected-item execution, single-use approval, unselected preservation and receipt-only permanent removal. Destructive test sinks are compiled only into the test executable and use isolated fixture directories.
- Initial adapter tests exercise real Mole discovery, exact selected-path grants, unknown rules, symlinks, and separate configuration/log roots under isolated test homes.
- Upstream Mole test run: 598 executed; one old-mail fixture depended on the real desktop Mail process. Mail was running, so the production guard correctly kept the file. `integration/mole/test-fixture.patch` isolates that fixture’s process state. The vendored source remains pristine.

## Required before public release

- [x] All 598 patched Mole safeguard tests passed with exit 0. Owner commands and specialized container-stub removals are explicitly informational in the capability matrix.
- [ ] No repeatable scan, first-map or rendering regression in paired release comparisons; investigate differences over 5%.
- [ ] App-and-worker memory, enrichment duration and interactive responsiveness measured.
- [ ] GUI behavior verified, including stale render discard and cleanup cancellation. Fixture startup rendered 13 nodes with zero unreadable directories; the desktop inspection tool hung before returning an accessibility tree or screenshot, so visual/interactive acceptance remains unverified.
- [ ] Fresh-machine install, offline operation and Full Disk Access onboarding verified.
- [ ] Minimum macOS 14 tested on a real machine or VM.
- [ ] Signed/notarized app and DMG assessed successfully.
- [ ] Real older-to-newer Sparkle update and tampered-update rejection verified.
- [ ] Draft release reviewed and published; signed appcast served over HTTPS.

A Developer ID Application identity was found in the user Keychain. A BurrowBolt Sparkle signing key was generated in Keychain; only the public key is in Git. The `burrowbolt-notary` Keychain profile was not present at the initial release preflight.
