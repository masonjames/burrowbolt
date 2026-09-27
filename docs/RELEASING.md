# Release procedure

1. Finish the acceptance checklist in `ACCEPTANCE.md`. Commit all changes; the release must match a clean tag.
2. Run `scripts/validate.sh`, `scripts/test-mole.sh`, the paired benchmarks, and GUI/installation checks. Record results against the exact commit.
3. Set `BURROWBOLT_SIGN_IDENTITY` to the Developer ID Application identity and `BURROWBOLT_NOTARY_PROFILE` to an existing `notarytool` Keychain profile. Private keys stay in Keychain. BurrowBolt’s Sparkle account is `burrowbolt`; its public key is `config/Sparkle.pub`. Never rotate it casually.
4. Tag and push `burrowbolt-v<VERSION>`. The prefix avoids collisions with inherited BlitzTree tags. Prepare release notes in a tracked Markdown file.
5. Run `./release.sh VERSION notes.md`. It signs nested code and the app, notarizes/staples the app, packages an Applications shortcut, signs/notarizes/staples the DMG, generates the signed appcast and checksums, and creates a **draft** GitHub release with corresponding source. It refuses existing versions and never overwrites an installer.
6. Verify a fresh install on macOS 14 and a current macOS version without development tools. Verify offline operation, FDA onboarding, signature assessment, cancellation, a real older-to-newer Sparkle update, and rejection of a tampered update. Test that updates wait while cleanup is active.
7. Publish the reviewed draft. Deploy its unchanged signed `appcast.xml` to GitHub Pages at `https://masonjames.github.io/burrowbolt/appcast.xml`. Keep the version-specific release asset immutable. Do not edit a signed feed without regenerating its signature.

`SUPublicEDKey`, `SURequireSignedFeed`, and `SUVerifyUpdateBeforeExtraction` are set in the release bundle. Automatic checks use Sparkle’s standard consent UI. Automatic installation is disabled. Development bundles do not start update checks.

Public release requires real notarization credentials; an ad-hoc development DMG is never a substitute. If the credentials are unavailable, retain the local artifacts and leave the release unpublished.
