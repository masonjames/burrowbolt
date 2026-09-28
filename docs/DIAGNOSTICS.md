# Diagnostics and telemetry

BurrowBolt currently has no Sentry, PostHog or other telemetry client. Running the development DMG sends us no automatic usage data, crash reports or logs. Signing identifies the publisher; it does not add analytics. Development builds disable Sparkle checks. Release builds use Sparkle only for updates, with system profiling explicitly disabled.

This is not a claim that the app never connects to the internet: automatic AI planning sends candidate paths, descriptions and sizes to the selected Claude/Codex provider. Update checks and optional agent installation also use the network. These are separate from developer telemetry.

## What is available locally

- macOS crash reports, when generated, are available in Console / Diagnostic Reports. They are not automatically delivered to this GitHub project.
- Worker lifecycle logs use Apple's unified logging subsystem `com.masonjames.burrowbolt`, category `worker`. They record startup/connection failure and pending-request counts, never paths, filenames, contents or AI prompts. Existing scan/timing diagnostics remain local; detailed renderer timings require `BZ_TIMING=1`.
- Cleanup history is `~/Library/Application Support/BurrowBolt/cleanup-history.ndjson`. It contains local per-item results and Trash paths, so it is sensitive and is not a redacted support bundle. The file is owned by the user and restricted to mode 0600. Mole's own local diagnostics live under `~/Library/Logs/BurrowBolt`.
- Builds retain matching app and Rust-worker dSYMs in `build/symbols`, separately from the app. Both packaging scripts archive these as `BurrowBolt-symbols.tar.gz`; keep them with the exact installer. Validation checks UUIDs and source line tables. `BurrowBoltSourceCommit` in Info.plist identifies the source revision of clean builds.

To inspect the worker log locally:

```sh
log show --last 1h --info --predicate 'subsystem == "com.masonjames.burrowbolt"'
```

Review a diagnostic report before sharing it: macOS reports and Mole logs can contain local paths. Never automatically upload the cleanup journal, Mole logs, inventory, or AI transcript.

## Recommended next integration

Start with **Sentry for opt-in crash and error reporting**. Its Apple SDK covers the native app; a separate worker process needs its own crash coverage or a deliberate parent-reported worker-exit event. An SDK in the Swift app alone does not capture every Rust-worker crash. Attach build version/commit and matching dSYMs. On macOS, configure uncaught NSException reporting deliberately and verify a real crash without a debugger, including delivery after restart.

Use an explicit consent setting, no default PII, and a small allowlist of diagnostic metadata. Disable file-I/O tracing, automatic network breadcrumbs, failed-request capture, screenshots, view hierarchies, replay and profiling initially. Scrub error messages and breadcrumb data before upload. Keep routine logs local; send only useful bounded failure context. Measure paired scan/first-map/worker-memory results with the SDK both disabled and enabled before shipping it.

Add **PostHog** only when we need product questions such as scan completion, treemap versus outline use, or cleanup-review abandonment. Capture a handful of explicit aggregate events after consent; no autocapture or session replay. App version, coarse duration/count buckets and outcome codes are sufficient. Never include file paths, names, installed-app inventories or AI prompts. Sentry and PostHog are complementary; neither is required for the offline scanning and cleanup functions.

Sources: [Sparkle system profiling](https://sparkle-project.org/documentation/system-profiling/), [Sentry macOS](https://docs.sentry.io/platforms/apple/guides/macos/), [Sentry data collection](https://docs.sentry.io/platforms/apple/data-management/data-collected/), [PostHog Apple SDK](https://posthog.com/docs/libraries/ios), [Apple unified logging](https://developer.apple.com/documentation/os/logging).
