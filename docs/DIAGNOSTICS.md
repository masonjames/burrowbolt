# Diagnostics and telemetry

BurrowBolt uses **Sentry for opt-in crash/error reports** and **macOS unified logging for local diagnostics**. Open **BurrowBolt → Settings** to enable reporting or send a test report. It starts disabled in both development and release builds. Signing does not enable it. Sparkle handles updates; system profiling stays disabled and development builds do not check for updates. There is no product analytics, session replay, or remote log streaming.

## Reporting and privacy

The native app uses pinned Sentry Cocoa 9.29.2. The worker uses Rust 0.49.3 with only panic, stacktrace, debug-image and system-libcurl transport features. The Rust inventory library never initializes telemetry. Both report to `mason-james-llc/borrowbolt` (the existing Sentry project's spelling). `config/Sentry.dsn` is a public ingestion address, not a private API token.

Reports retain code stack addresses/symbols, binary UUIDs, build version/commit, environment and component. Native reports also include macOS version and architecture. Handled errors use fixed codes, once per code per app process; expected cleanup refusals are not reported as crashes. The payload allowlists discard exception/panic text, scanned paths, file names, file contents, cleanup history, AI prompts, request data, breadcrumbs, thread names, device identifiers and arbitrary context. Native standard exception types are retained; unknown types are replaced. Uploaded developer dSYMs can supply **source-code** locations, which are distinct from scanned files.

`sendDefaultPii` / `send_default_pii` remain false. Automatic network/error capture, file tracing, sessions, metrics, logs, tracing, profiling, replay and screenshots are disabled or unavailable in the macOS SDK. An unspecified IP (`0.0.0.0`) prevents ingestion from deriving location from the connection, and project-side IP scrubbing is enabled. Sentry necessarily receives the network connection when a consented report is sent.

SDK startup is queued on the main event loop, as required by the Cocoa SDK; Rust scanning can start before initialization completes. Report capture and consent changes use that same queue. The worker receives initial consent at launch and subsequent changes through its existing protocol; its input reader revokes permission even during a running probe. Turning reporting off prevents new reports and removes the native SDK cache. A report already in flight may finish; turning reporting off cannot recall reports already received by Sentry. Cleanup is never interrupted by a diagnostics setting change.

Native crashes are delivered on a subsequent consented launch. Rust panics attempt delivery with a two-second flush limit; offline worker reports are best effort and are not persisted. Hard worker termination is detected by the app when the connection closes; it does not provide a native worker crash stack. Startup failures before SDK initialization, hangs and forced kills are not comprehensive crash coverage.

This setting is separate from automatic AI planning, which sends candidate context to the selected Claude/Codex provider. No diagnostics permission authorizes AI access to additional files.

## Local diagnostics

Unified logs use subsystem `com.masonjames.burrowbolt`, categories `app` and `worker`: startup, scan duration/completeness, first-map readiness, cleanup lifecycle/result counts, worker connections and stable failure codes. There are no per-file log calls in the scanner or renderer. Detailed local timing diagnostics remain available with `BZ_TIMING=1`.

```sh
log show --last 1h --info --predicate 'subsystem == "com.masonjames.burrowbolt"'
```

The native SDK cache is under `~/Library/Application Support/BurrowBolt/Diagnostics/com.masonjames.burrowbolt` with directory mode 0700 and a ten-event cache limit. Local crash state can contain more detail than the scrubbed upload. macOS also retains its own crash reports in Console / Diagnostic Reports.

The separate `cleanup-history.ndjson` journal under `~/Library/Application Support/BurrowBolt` contains sensitive per-item results and Trash paths, with mode 0600. Mole logs live under `~/Library/Logs/BurrowBolt`. None of these files is attached to Sentry. Review local reports before sharing them.

## Verification and symbols

`scripts/validate.sh` runs the native opt-out/opt-in/revocation/cache/scrubbing checks and Rust privacy/consent checks without sending test events. The test app has its own bundle identifier, preferences and cache. To deliberately send synthetic SDK events:

```sh
benchmarks/run-diagnostics.sh send
# Optional: this crashes only the isolated fixture app; restart to deliver it.
benchmarks/run-diagnostics.sh crash
benchmarks/run-diagnostics.sh send
cargo test --locked --release --features cli,diagnostics --bin burrowbolt-worker \
  diagnostics::tests::verify_sdk_panic -- --ignored --nocapture
```

Production binaries contain no test panic command. Rust's ignored panic test uses a test executable, so its debug UUID differs from the bundled worker. Native fixture crashes likewise use the fixture's UUID. Confirm receipt, component, release and scrubbed contents in Sentry; a successful local flush alone does not prove ingestion.

Builds save exact app/worker dSYMs under `build/symbols`. Both packaging scripts retain `BurrowBolt-symbols.tar.gz`. `release.sh` uploads the matching symbols to the configured Sentry project using authenticated `sentry-cli` before making a draft release. For development builds:

```sh
sentry-cli debug-files upload --org mason-james-llc --project borrowbolt --wait build/symbols
```

Use existing credential storage or the release runner's secret environment for authentication; never put an auth token in the app, repository or chat. Preserve symbols for every distributed installer. App and worker releases use the app version plus source commit; development and production environments are separate. Builds include the SDK licenses and releases include pinned Cocoa source and vendored Rust dependencies.

Sources: [Sentry macOS](https://docs.sentry.io/platforms/apple/guides/macos/), [Sentry data collection](https://docs.sentry.io/platforms/apple/data-management/data-collected/), [Sparkle profiling](https://sparkle-project.org/documentation/system-profiling/), [Apple unified logging](https://developer.apple.com/documentation/os/logging).
