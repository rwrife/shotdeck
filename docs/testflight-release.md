# ShotDeck TestFlight release runbook

This document describes the signed TestFlight release pipeline for ShotDeck (`com.infinityball.shotdeck`), credentials handling, failure modes, and recovery procedures.

## Prerequisites and repository secrets

The pipeline authenticates with App Store Connect using an API key stored in GitHub Actions secrets. Only the following secret names are authorized:

- `ASC_KEY_ID`: App Store Connect API Key ID (e.g. `ABC1234567`).
- `ASC_ISSUER_ID`: App Store Connect Issuer ID UUID.
- `ASC_KEY_P8`: Private key contents in PKCS#8 format (`-----BEGIN PRIVATE KEY----- ... -----END PRIVATE KEY-----`).
- `ASC_TEAM_ID`: Apple Developer Team ID (10 alphanumeric characters).

Secret values must never appear in repository files, commit messages, issue comments, pull request descriptions, or CI logs.

## Pipeline structure (`.github/workflows/release.yml`)

The workflow runs on `macos-15` runners with the exact pinned toolchain (Xcode 26.0.1 / 17A400 / iOS SDK 26.0):

1. **Trigger modes:**
   - Manual `workflow_dispatch` with boolean input `upload` (defaults to `false` for signed dry runs).
   - Tag push matching `v*` (e.g. `v0.1.0`), which defaults to `upload=true`.
2. **Ephemeral private storage:**
   - Raw logs and private key material are placed in `$RUNNER_TEMP/shotdeck-release-private` with mode `0700`.
   - The `.p8` key is written with mode `0600`.
   - On completion or failure, the directory is deleted via an `always()` step.
3. **Pre-build assertions:**
   - Validates `ShotDeck.xcodeproj` build settings for `PRODUCT_BUNDLE_IDENTIFIER = com.infinityball.shotdeck`, `TARGETED_DEVICE_FAMILY = 1`, `IPHONEOS_DEPLOYMENT_TARGET = 26.0`, and `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.
   - Verifies the exact Xcode 26.0.1 / 17A400 / SDK 26.0 toolchain exists and activates it.
4. **Archive & verification:**
   - Archives scheme `ShotDeck` with automatic signing via the ASC API key.
   - Inspects the built `ShotDeck.xcarchive/Products/Applications/ShotDeck.app/Info.plist`:
     - `CFBundleIdentifier == com.infinityball.shotdeck`
     - `UIDeviceFamily == [1]` (iPhone only; iPad family 2 is forbidden)
     - `CFBundleVersion == <run_number>.<run_attempt>`
     - `PrivacyInfo.xcprivacy` present
     - `Assets.car` and compiled `AppIcon` assets present
   - Deep strict code-signature verification with `codesign --verify --deep --strict`.
5. **Export & upload:**
   - Exports the archive using `ExportOptions.plist` configured for `method=app-store-connect` and `signingStyle=automatic`.
   - When upload is requested, sets `destination=upload` and `uploadMethod=app-store-connect`.
6. **Processing poll:**
   - Generates an ES256 JWT using the raw P-256 signature format (`r || s`, 64 bytes).
   - Queries `GET /v1/apps?filter[bundleId]=com.infinityball.shotdeck`.
   - Polls `GET /v1/builds?filter[app]=<app_id>&filter[version]=<build_number>` every 30 seconds (up to 15 minutes).
   - Requires `processingState == "VALID"` to succeed.
7. **Curated evidence publication:**
   - Publishes `build/release-evidence` as an artifact:
     - `provenance.json`: source commit, run number, attempt, toolchain versions.
     - `archive-metadata.json`: bundle ID, device family, icon, privacy manifest, code-sign status.
     - `processed-build.json` (when uploaded): build ID, build number, state, upload timestamp.
     - `*-summary.json`: exit codes and fixed-vocabulary error counts; on failed subprocesses, `diagnostics` lists recognized fixed codes only (never raw log lines). Unrecognized errors produce an empty list, not a diagnosis.

## Failure modes and recovery

When an error occurs, `release.py` suppresses raw exception text and logs to prevent sensitive signing fragments from entering GitHub Actions output. The runner console prints a generic message:
```text
Release blocked. Inspect curated evidence (categories + fixed diagnostic codes) and the runbook; raw signing output is not published.
```

To triage the phase without publishing raw signing output:
1. Download the `release-evidence-<run_id>-<attempt>` artifact. No artifact can also mean validation failed before evidence creation or artifact upload itself failed.
2. Use `provenance.json`, `archive-metadata.json`, and the set of `<phase>-summary.json` files to locate the last recorded phase. A nonzero subprocess exit appears in its summary, with fixed-vocabulary category counts (`provisioning`, `signing-certificate`, `appstore-auth`, `app-identity`, `compiler-or-build`) and a `diagnostics` list of recognized fixed codes (`certificate-limit`, `certificate-revocation-required`, `no-provisioning-profile`, `authentication-failed`, `agreement-required`, `missing-package-product`, `missing-module-dependency`, `missing-ios-platform`). These are hints, not diagnoses; an empty `diagnostics` list means the failure text matched no known signature.
3. A zero-exit summary records only the subprocess result. Subsequent checks can still fail: `verify_settings()` after the `settings` phase, archive metadata checks after `archive`, or ASC lookup/polling after `export-upload`. Those checks do not emit a phase summary. Neither a missing summary nor an absent `processed-build.json` alone identifies a specific cause.
4. When further diagnosis needs sensitive Xcode or Apple response details, run on a trusted interactive Apple host and inspect private output there. Do not paste raw logs or credentials into GitHub artifacts/issues.

Possible root causes and their remediation:

### 1. Missing or unmeasurable Xcode toolchain
- **Symptom:** Workflow fails during preflight with exit code 1; no summary files produced in `build/release-evidence`.
- **Cause:** The runner image does not have the pinned Xcode version installed.
- **Recovery:** Re-run on a runner image that provides the pin (`macos-15`). Do not downgrade toolchain requirements.

### 2. Apple certificate ceiling exceeded
- **Possible clue:** Archive phase exits with code 65; `archive-summary.json` may show a positive count for `signing-certificate`.
- **Possible cause:** The Apple Developer Team has reached the maximum number of active development or distribution certificates.
- **Recovery:** Account administrator inspects active certificates in App Store Connect and revokes unused ephemeral certificates. Never attempt automatic certificate revocation from CI automation.

### 3. Missing App Store Connect app record
- **Possible clue:** Step fails during or after export; `provenance.json` exists but no `processed-build.json` is generated.
- **Possible cause:** Bundle ID `com.infinityball.shotdeck` has not been registered or created in App Store Connect for the team, or API access is not configured.
- **Recovery:** Verify the app record in App Store Connect under the infinityball team with bundle ID `com.infinityball.shotdeck`.

### 4. Build processing failure (`FAILED` or `INVALID`)
- **Possible clue:** Step fails after upload during polling; `processed-build.json` is absent.
- **Possible cause:** Apple backend processing encountered a binary validation error (e.g. missing icon, invalid entitlement, missing privacy description).
- **Recovery:** Review the email notification sent by App Store Connect to the account owner; patch the issue in a new pull request on `main`, merge, and tag a new patch release.

### 5. Simulator runtime flake during CI test phase
- **Symptom:** Simulator boot or list times out in `ci.yml`.
- **Cause:** Hosted runner simulator daemon stall.
- **Recovery:** Use `gh run rerun <run_id> --failed`. Do not push empty commits.
