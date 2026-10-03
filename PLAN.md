# ShotDeck Plan

## Scope

Build a native Swift iPhone-only app that keeps shot planning, take logging, and continuity evidence local-first. The MVP covers one creator or one small crew using a single device at a time, with deterministic coverage and transparent export.

This plan is intentionally scaffold-stage: architecture, contracts, and acceptance criteria are defined; implementation code and Xcode project setup are tracked by issues.

## Product architecture

### Domain layer (`Packages/ShotDeckKit`)

Pure Swift package with no UI or Apple framework dependencies beyond Foundation.

Core entities:

- `Project`
- `Scene`
- `Shot`
- `Take`
- `ContinuityCheck`
- `SessionEvent`
- `CoverageSummary`

Rules:

- Append-only take history; edits create revisions or explicit replacements with audit markers.
- Candidate take selection is explicit and nullable.
- Coverage states are deterministic and named (`not_started`, `attempted`, `candidate_selected`, `omitted`, `unknown`).
- Unknown-safe behavior: missing timing, camera, or continuity info can only degrade certainty; never silently upgraded to complete.

### Persistence layer (`Packages/ShotDeckStore`)

- SQLite via GRDB in app container.
- Versioned migrations with fixture snapshot tests.
- App-private media references for imported/captured stills.
- Transactional write boundaries around shot/take mutations.
- Durable export codec versioning for JSON backup and CSV/PDF report generation.

### App layer (`ShotDeck`)

SwiftUI-first app with focused UIKit bridges where needed.

Primary surfaces:

1. Project list and creation.
2. Scene + shot planner.
3. Shoot workspace (selected shot, continuity list, take controls).
4. Coverage and unresolved-state review.
5. Export/import and privacy controls.

A single `ShootWorkspaceLayout` abstraction owns pane arrangement and fold-state migration rules for future iPhone Duo support.

### Accessibility and resilience

- Dynamic Type up to accessibility categories.
- VoiceOver labels/hints for shot and take controls.
- Non-color-only status indicators.
- Deterministic keyboard focus and rotor ordering for external keyboard workflows.
- Crash-safe restore of active project/session pointers.

## Technology choices

- **Swift 6 + SwiftUI/UIKit:** required native stack; no cross-platform layer.
- **iOS 26 SDK+ (pinned to Xcode 26.0.1 / iOS 26.0 initially):** policy requirement and deterministic CI behavior.
- **GRDB + SQLite:** local, inspectable, migration-friendly persistence.
- **Swift Testing + XCTest + XCUITest:** pure-domain determinism, persistence integration, and iOS interaction validation.
- **PDFKit/CoreGraphics for report export:** native PDF generation and printability.

## iOS platform policy (non-negotiable)

- iPhone-only MVP: `TARGETED_DEVICE_FAMILY = 1` in all app-target configurations.
- Native iPad support disabled unless explicit opt-in is requested later.
- Android out of scope.
- Forbidden frameworks: Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity.
- Bundle prefix rule: `com.infinityball.*` only; this repo uses `com.infinityball.shotdeck`.

## Milestones and dependency order

### M1 — Scaffold + CI contract
*(Delivered in issue #1)*

- Created `ShotDeck.xcodeproj` with app target bundle identifier `com.infinityball.shotdeck` and `TARGETED_DEVICE_FAMILY = 1` across all configurations.
- Added `Packages/ShotDeckKit` with pure Swift 6 domain skeleton, compiling placeholder target, and green swift-testing suite.
- Wired `.github/workflows/ci.yml` running Linux package tests (`swift:6.2-noble`), zero-network gate, native-only framework guard, signing-material exclusion, and macOS exact-toolchain pin assertion (`Xcode 26.0.1 (17A400)`, iOS SDK 26.0) with built `UIDeviceFamily == [1]` verification.
- Run commands documented in README.md quickstart.

### M2 — Domain + persistence core
*(Domain slice delivered in issue #2: `Packages/ShotDeckKit` entities, append-only take ledger, and unknown-safe coverage engine with table-driven tests. Persistence slice delivered in issue #3: `Packages/ShotDeckStore` GRDB/SQLite store with named v1/v2 migrations, explicit ordered retrieval repositories, transactional take-ledger appends, explicit nullable candidate selection, a committed v1 fixture (`Fixtures/shotdeck-fixture-v1.sqlite`), and the `ShotDeckFixtureTool` generate/verify CLI.)*

- Implement entities, coverage engine, and unknown-safe semantics.
- Implement migrations and fixtures.
- Add deterministic unit/integration tests.

### M3 — Core planning workflow
*(Planner slice delivered in issue #4: `ShotDeck` app now runs the planner flow — project list/create/edit/delete, scene list with reorder + status cycling, ordered shot-list editor with move/insert, archive & omit states, user-owned reusable framing tags, lens/orientation/movement metadata, action notes, and reference metadata fields. All planner logic lives in the pure `PlannerModel` in `Packages/ShotDeckKit` (Linux + Apple tested); persistence gained schema `v3-planner-metadata` (shot planner columns + explicit project order) in `Packages/ShotDeckStore`. Non-color status = glyph + spoken text on every row, VoiceOver labels/hints on all controls, Dynamic Type via system fonts/`.caption` styles, and an XCUITest journey asserting the accessibility identifiers.)*

- Build project/scene/shot CRUD.
- Add ordering, tagging, and validation states.
- Add accessibility audits for editor surfaces.

### M4 — Shoot workspace + continuity

- Implement fast take logger, candidate selection, continuity checklist, and unresolved-state review.
- Implement crash-safe active-session restoration.
- Define and test `ShootWorkspaceLayout` seam for future dual-screen adaptation.

### M5 — Export/backup/privacy controls

- JSON backup/restore with previewed replace.
- CSV and PDF report generation.
- Permission-copy and privacy disclosures in-app.

### M6 — Release hardening

- Native Apple-runner verification (build/tests on pinned toolchain).
- Archive/sign/upload to TestFlight via App Store Connect API keys.
- Record processed-build evidence before release claims.

## Testing strategy

1. **Domain tests (Linux + Apple):** deterministic coverage, ordering, unknown-safe semantics.
2. **Store tests (Linux + Apple):** migration correctness, transaction behavior, fixture compatibility.
3. **App unit tests (Apple):** state reducers/view models.
4. **UI journeys (Apple):** planning to take logging to export, including accessibility probes.
5. **Contract checks:** enforce `TARGETED_DEVICE_FAMILY = 1`, exact bundle ID, and iOS 26+ SDK in CI.
6. **Regression fixtures:** pinned JSON/PDF/CSV fixture comparisons for export stability.

No claim of app correctness is valid from Linux-only checks.

## Packaging and distribution

- App Store/TestFlight path only for MVP.
- CI secrets (names only): `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID`.
- Bundle registration status: `CREATED com.infinityball.shotdeck`.
- Release requires: archive metadata proof, processed TestFlight build ID, and reproducible changelog evidence.

## Risks and mitigations

- **Risk:** scope creep into full production-management suite.
  - **Mitigation:** backlog enforces shot/take/continuity core only; explicit non-goals.
- **Risk:** ambiguity in coverage semantics.
  - **Mitigation:** table-driven rule engine and golden tests for each state transition.
- **Risk:** privacy erosion through media handling.
  - **Mitigation:** app-private media storage defaults, explicit export previews, no background uploads.
- **Risk:** foldable narrative without API support.
  - **Mitigation:** keep dual-screen as documented design target through `ShootWorkspaceLayout` seam only.
- **Risk:** accidental platform drift.
  - **Mitigation:** CI gating for iPhone-only device family and native-only stack strings.

## Explicit non-goals

- No cloud collaboration or account system.
- No NLE/editor replacement, ingest pipeline, or media transcoding.
- No auto-continuity AI judgments, face recognition, or model inference requirements.
- No Android implementation.
- No native iPad implementation in MVP.
- No Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, or Unity.
- No claim of native iPhone Duo runtime support until Apple publishes and tooling verifies it.
