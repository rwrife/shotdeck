# ShotDeck

Local-first iPhone shot-list and continuity workspace for solo creators: plan frames, log takes, match reference details, and export clear production reports — no accounts, no cloud.

## Overview

ShotDeck helps solo filmmakers, photographers, and small volunteer crews move from a planned shot list to an honest record of what was captured. A project contains ordered scenes and shots; each shot can carry framing notes, a reference image, continuity checks, and append-only take records. The app derives coverage from that ledger instead of asking users to remember which angles still need work.

This repository includes the native Swift iPhone-only app shell (`ShotDeck.xcodeproj`, `ShotDeck/`, `ShotDeckUITests/`), the pure domain package (`Packages/ShotDeckKit`), the local SQLite store (`Packages/ShotDeckStore`, schema v3), the accessible shot planner, shoot workspace, and user-initiated local portability controls. CI gates cover exact toolchain pinning, zero-network enforcement, native-only framework policy, iPhone-only bundle metadata, and UI journeys. Signed TestFlight release automation remains tracked as a follow-up issue.

## Motivation

Large production suites optimize for crews, accounts, subscriptions, and cloud collaboration. Notes apps and camera rolls do not connect an intended frame to takes, continuity observations, and coverage. ShotDeck keeps that focused workflow private, portable, and usable when a location has no network.

## Target users

- Solo video creators recording tutorials, interviews, short films, and product demos.
- Photographers planning repeatable product, portrait, or location shot sets.
- Student and volunteer crews that need a simple, transferable shot record.
- Creators who want local data ownership instead of a production-platform account.

## Intended workflow

1. Create a project and define scenes or setup groups.
2. Add ordered shots with framing, lens/focal-length text, orientation, movement, dialogue/action notes, and optional user-owned reference images.
3. Start a shoot session and select the current shot.
4. Record each take with a timestamp, duration when known, rating/status, notes, and explicit continuity observations.
5. Mark the preferred take or leave the choice unresolved; ShotDeck never silently treats the newest take as selected.
6. Review coverage with named states: not started, attempted, candidate selected, or intentionally omitted.
7. Export a versioned JSON backup and human-readable CSV/PDF production reports through the Files share sheet.

## MVP features

- Project, scene, shot, take, and continuity-check domain model with stable IDs.
- Ordered shot-list editor with reusable user-owned framing tags.
- Optional app-private reference and continuity stills with captions and timestamps.
- Fast take logger with undo-safe edits, candidate selection, and explicit unresolved state.
- Deterministic coverage summary with named exclusion and incomplete-data reasons.
- Search and filters for scene, setup, status, tag, and incomplete continuity checks.
- Versioned JSON backup/restore with preview and transactional replacement.
- CSV shot/take export and a printable PDF shoot report.
- Dynamic Type, VoiceOver, non-color-only status, Reduce Motion, keyboard focus, and minimum hit-target support.
- A single `ShootWorkspaceLayout` seam for future iPhone Duo adaptation.

## iPhone Duo design target

The future dual-screen workspace gives each display a stable job: one screen holds the selected shot, reference still, and continuity checklist while the other remains a large take-control surface and coverage queue. Selection, active session state, and draft notes must survive folding or unfolding.

The current build shape is a standard native iPhone app. Native iPad support is disabled by default. No unavailable foldable or hinge API is required. When Apple publishes supported dual-screen APIs, `ShootWorkspaceLayout` will translate safe regions, pane placement, and fold transitions without changing the domain or persistence layers. Tablet layouts remain deferred unless the user explicitly opts in.

## Shoot workspace (local-only)

From a scene's shot list, open **Shoot workspace** and choose a shot to start or change the active session. The large **Log take** button appends an immutable record with a timestamp, rating, notes, and optional user-entered duration (positive seconds) and camera/source. The take list permits explicit candidate selection; no latest-take auto-selection occurs. Missing duration or camera/source on a candidate produces **unknown** coverage rather than inventing capture facts. Add required continuity checks with a label; each starts **pending** until marked Matched, Mismatch, or Unresolved. Coverage reasons remain visible even when a candidate is selected. Ending a shoot clears the active shot; quitting and reopening replays the local session event log in append order, falling back to unresolved if a referenced shot is gone. A failed database open or write is surfaced, never treated as a successful capture.

`ShootWorkspaceLayout` is a logic-only seam: folded and unknown map to one active-shot panel; unfolded maps to shot plus take-ledger panels. This is **not** a claim of fold detection or dual-screen hardware support. The app currently renders only the folded iPhone workspace.

## Platform contract

- Native Swift 6 with SwiftUI/UIKit and standard Apple tooling only.
- iPhone-only; Android and native iPad support are out of scope.
- iOS 26 SDK or newer is mandatory; the initial pin is Xcode 26.0.1 (17A400), iOS SDK 26.0, deployment target iOS 26.0.
- Every app-target configuration must set `TARGETED_DEVICE_FAMILY = 1`; an Apple runner must verify built `UIDeviceFamily` equals `[1]` before release evidence is accepted.
- Bundle identifier and `PRODUCT_BUNDLE_IDENTIFIER`: `com.infinityball.shotdeck`.
- App Store Connect bundle registration: `CREATED com.infinityball.shotdeck`.

## Privacy, permissions, and storage

- All records and app-managed media are local by default in the app container. Core planning and take logging work with networking disabled.
- No account, cloud sync, ads, analytics SDK, tracker, or server is part of the MVP.
- Photos access uses user-selected Photos picker imports rather than full-library scanning.
- Camera access is optional and requested only when the user captures a reference or continuity still. Denial leaves text notes and imports usable.
- Files access is user-initiated for import/export. No contacts, microphone, location, background tracking, or notification permission is required.
- Exports may contain production notes and images; the confirmation screen names included data before sharing.
- Users must have rights to imported reference media. ShotDeck does not source, scrape, or redistribute copyrighted imagery.

## Non-goals

- No camera replacement, video recording, editing, color grading, asset transcoding, waveform, slate synchronization, or media ingest.
- No cloud collaboration, crew chat, call sheets, scheduling, payroll, casting, location releases, or production accounting.
- No generative AI, visual matching claims, automatic continuity judgment, face recognition, or quality scoring.
- No Android or native iPad release work without explicit user opt-in.
- No Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity, or another cross-platform/hybrid framework.
- No claim of native iPhone Duo compatibility before public Apple hardware and SDK evidence exists.

## Status and milestones

1. Native iPhone skeleton, exact-toolchain CI, and iPhone-only enforcement. *(Landed: `ShotDeck.xcodeproj`, `Packages/ShotDeckKit`, `.github/workflows/ci.yml`.)*
2. Pure Swift domain and coverage engine. *(Landed.)*
3. Local SQLite database. *(Landed: `Packages/ShotDeckStore`.)*
4. Shot-list planning and accessible take workflow. *(Landed: Planner views.)*
5. Continuity review and shoot workspace. *(Landed: issue #5.)* Backup/restore, reports, and privacy controls are in issue #6.
6. Native verification, archive, signed TestFlight upload, and processed-build evidence. *(Issue #7.)*

See [PLAN.md](PLAN.md) and the GitHub issue backlog for dependency order.

## Development quickstart

The workspace exists with the exact toolchain pin in `toolchain.json` (Xcode 26.0.1 / 17A400 / iOS SDK 26.0):

```bash
xcodebuild -version
xcodebuild -showsdks
swift test --package-path Packages/ShotDeckKit
swift test --package-path Packages/ShotDeckStore   # Linux needs libsqlite3-dev
swift run --package-path Packages/ShotDeckStore ShotDeckFixtureTool verify Fixtures/shotdeck-fixture-v1.sqlite
xcodebuild -project ShotDeck.xcodeproj -scheme ShotDeck -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
bash scripts/check_zero_network.sh
bash scripts/check_native_only.sh
```

CI runs the same commands: `linux-package` exercises both package test suites (installing `libsqlite3-dev` for GRDB's systemLibrary Linux path) plus the fixture migration verification and the zero-network, native-only, and signing-material gitignore gates in a `swift:6.2-noble` container; `ios-build` asserts the exact Xcode pin, runs both package suites on the Apple toolchain, builds for `iphonesimulator`, and verifies built `UIDeviceFamily == [1]`, `com.infinityball.shotdeck`, and the embedded privacy manifest.

## Distribution

CI will use the secret names `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, and `ASC_TEAM_ID`; values never belong in source, logs, issues, or reports. Release work must build with the pinned iOS 26+ toolchain, enforce `com.infinityball.shotdeck`, archive with iPhone-only metadata, upload through App Store Connect, and record the processed build ID before claiming TestFlight success.

## License

MIT. See [LICENSE](LICENSE).
