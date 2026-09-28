# Maintaining BurrowBolt

`origin` in the original checkout remains BlitzTree; the shared local repository has a separate `burrowbolt` remote. In a fresh clone of BurrowBolt, `origin` is the fork. Keep one ordinary merge history for the application and one pristine, squashed Mole subtree. Do not rebrand Rust symbols, restructure the application, or modify `vendor/mole` to make a downstream feature fit.

`UPSTREAMS.lock` pins reviewed upstream commits and Sparkle/toolchain versions. `integration/mole/state.patch` changes only Mole-owned state locations in the build copy. `readonly.patch` exposes installer inspection without launching a terminal UI, retains fail-closed process evidence through lsappinfo, and reports owner-command/container-stub findings without enabling their special removal sinks. It is applied with zero fuzz; drift fails the build. `integration/mole/test-fixture.patch` isolates one upstream test from the real desktop Mail process. `scripts/test-mole.sh` runs the upstream suites against a separate patched copy and adapts expected state-directory names to the intentional BurrowBolt namespace.

For BlitzTree, merge the chosen upstream commit, resolve product differences, and update the lock. For Mole, use `git subtree pull --prefix vendor/mole https://github.com/tw93/Mole <commit> --squash`, update the lock, and review integration patch application. Each update belongs in its own PR. The weekly workflow opens draft PRs but does not merge or enable new destructive rules. A BlitzTree merge conflict opens a draft integration-report PR with the conflicting paths and unchanged upstream pin; the revision is not presented as imported. Resolve the merge and update the lock before marking it ready. Other integration failures stop the workflow rather than selecting a side automatically.

## Capability boundary

| Family | Discovery / execution | Protection / check |
|---|---|---|
| Project artifacts | Native inventory recognizes all 34 pinned Mole target names; exact selected paths use the project adapter | Actual project root, excluded artifact ancestors, authored-content guard, 7-day activity guard, complete process/open-handle evidence, common Mole guards, worker identities; purge Bats + adapter tests |
| Installers | DMG, PKG, MPKG, ISO, XIP from inventory; selected user-owned regular files can be reviewed for Trash | Mole common guards, complete process/open-handle evidence + worker containment/identity; installer Bats + worker selected-item fixture |
| Installer ZIP / other archives | Deferred per-archive inspection reuses Mole `is_installer_zip`; non-installer archives remain informational | Complete bounded listing, no cloud placeholders or symlinks, complete process/open-handle check; installer_zip Bats + adapter fixtures |
| User essentials and logs | `clean_user_essentials`, structured dry-run records; only `_safe_clean_impl` records can become selective actions | Original per-action callback and common protection predicates; clean_core Bats |
| App caches | `clean_app_caches` | Original owner, SQLite, protected-data and final callback checks; clean_core / app_caches Bats |
| Browser data | `clean_browsers` | Original process guards; browser state outside its cache rules remains protected |
| Cloud and Office | `run_cloud_and_office_cleanup` | Upstream process/data guards; cloud placeholders never authorize generic deletion |
| Developer tools | `clean_developer_tools` | Original file-target guards; owner-tool commands are informational until represented as typed actions |
| GUI app caches | `clean_user_gui_applications` | App-specific predicates retained; app_caches Bats |
| Virtualization and containers | `clean_virtualization_tools` plus native storage insights | Only guarded file targets are eligible; container images, volumes and databases stay informational |
| Application Support logs | `clean_application_support_logs` | Exact upstream log paths and safeguards |
| Orphaned application data | `clean_orphaned_app_data` | Complete installed-owner evidence, age and final eligibility callback; clean_apps Bats |
| Orphaned container stubs | `clean_orphaned_container_stubs` read-only | Its special nonrecursive metadata/rmdir sink is not replaced with generic folder Trash; informational |
| Apple Silicon caches | `clean_apple_silicon_caches` | Only user-owned guarded records; system-owned paths fail worker scope checks |
| Cached device firmware | `clean_cached_device_firmware` | Exact upstream guarded file targets |
| CACHEDIR.TAG | Native inventory plus 43-byte signature check | Regular local tag only; tag alone does not authorize removal |
| Old Downloads | Native inventory, 90-day mtime insight | Age alone is not permission; informational |
| Backups and Xcode archives | Native inventory insights | Informational; recovery data is not generically disposable |
| Local snapshots | Bounded `tmutil listlocalsnapshotdates /` | Count only, unknown size; no deletion |
| Restricted system data | Existing disk inventory and incomplete coverage | Informational; no elevation or privileged cleanup |

Mole emits some useful targets only through specialized sinks or owner commands. These remain explicitly informational rather than being routed through a weaker generic action. These informational classifications implement the agreed rule that unsupported owner-specific actions stay unavailable. Validate actual family discovery on representative machines before release; fixture coverage does not prove every installed-tool combination.

## Worker protocol

The app starts one bundled `burrowbolt-worker` and speaks version-1 NDJSON over pipes. A `discover` request contains the scan generation, root, exclusions and sparse candidates (`candidateID`, path, category, observed allocated bytes, completeness). Full inventory arrays never cross this boundary. `enrich` runs one pinned family under a deadline; `measure` binds its records back to nodes in the existing inventory.

`plan` accepts selected IDs, rechecks their identities and Mole guards, and returns a single-use token. `apply` requires that generation/token and a subset of those IDs. Each result is `trashed` or `refused`; cancellation prevents later items. A successful Trash move produces a receipt. `empty` accepts only those worker-owned receipts with separate permanent-removal confirmation. The app never executes AI-provided shell strings.

A family is rerun in dry-run mode for selected-item validation. The adapter emits a grant only at the exact path inside `_safe_clean_impl`, after the original dynamically scoped callback and common protection checks. The worker receives that grant immediately, stops the probe process group, rechecks file and ancestor identities, and calls Foundation’s native Trash API. It never invokes unrestricted `mo clean` or uses terminal prose as an API.

## Performance gates

Use optimized builds and alternating AB/BA runs over identical inputs. `benchmarks/scan.py` records counts, times and memory; totals must match. `benchmarks/rendering.py` checks geometry/pixels and benchmarks the retained renderer. Its `RENDER_BENCHMARK` flag makes the canvas synchronous only inside the offscreen timing harness; production coalesces work off the main actor. Test scheduling and stale-result behavior separately through the actual app.

Treat 5% as an investigation trigger. Do not accept a repeatable regression because it is smaller than that. Measure first-map latency, app plus worker footprint, enrichment duration, and navigation responsiveness separately; unrelated processes and changing inputs invalidate paired comparisons.

Archive discovery uses inventory metadata immediately. Automatic archive listings share a 20-second background budget (an already-running bounded probe may finish afterward); remaining archives stay informational with an inspector action for selected-file inspection. The deadline does not authorize partial listings. A failed inspection can be retried, but a changed identity requires a new scan.

Native project/installer cleanup reuses Mole's complete-process-visibility predicate. If macOS hides privileged processes from the worker, eligibility remains unknown and cleanup is refused. BurrowBolt never requests elevation to turn that unknown into permission. Adapter fixtures explicitly supply root-visibility evidence while retaining real target-handle queries; they are separate from fresh-machine acceptance.

The `BurrowBolt checks` workflow also runs alternating scanner/first-map measurements on a fixed 50,000-file wide directory plus a 200-level deep tree, and Retina renderer comparisons. Three fixed rounds retain all measurements: differences above 5% in at least two rounds fail for investigation; single-round spikes remain warnings for review, and smaller repeatable regressions still require review. The immutable `performance_baseline` is separate from the moving upstream pin. Hosted runners do not replace paired local/external-drive measurements.
