import Foundation
import Observation
import ShotDeckKit
import ShotDeckStore

/// App-side planner state (issue #4).
///
/// Owns the planner document (the pure `PlannerModel` from ShotDeckKit —
/// validation, ordering, and unknown-safe rules live there and are
/// unit-tested on Linux and Apple lanes) and persists it to the local
/// SQLite store (`ShotDeckStore`, app container file only). Persistence is
/// write-through: every mutation is attempted in the database FIRST and
/// only applied to the in-memory model on success, so the UI can never
/// show data the store rejected. Opens no network access (zero-network
/// gate enforces this in CI).
@MainActor
@Observable
final class PlannerStore {
    private var model: PlannerModel
    private let persistence: ShotDeckStore?
    /// Invalidates derived coverage and session labels after durable writes.
    private var shootRevision = 0

    /// Non-nil when the local store could not be opened or a write failed —
    /// surfaced verbatim in the UI instead of silently dropping edits.
    var persistenceIssue: String?

    init() {
        let loaded = Self.openLocalStore()
        self.persistence = loaded.store
        self.model = loaded.model
        self.persistenceIssue = loaded.startupIssue
    }

    /// Test/preview seam: in-memory document with no persistence.
    init(model: PlannerModel) {
        self.persistence = nil
        self.model = model
    }

    /// Opens the app-container SQLite store and hydrates the planner
    /// document. `--ui-tests` (simulator journeys) gets a per-process
    /// temporary database so every launch starts from an honest empty state.
    private static func openLocalStore() -> (store: ShotDeckStore?, model: PlannerModel, startupIssue: String?) {
        let url: URL
        if CommandLine.arguments.contains("--ui-tests") {
            if let index = CommandLine.arguments.firstIndex(of: "--ui-tests-persist"),
               CommandLine.arguments.indices.contains(index + 1),
               let token = UUID(uuidString: CommandLine.arguments[index + 1]) {
                url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("shotdeck-uitests-\(token.uuidString).sqlite")
            } else {
                url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("shotdeck-uitests-\(UUID().uuidString).sqlite")
            }
        } else {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            url = dir.appendingPathComponent("shotdeck.sqlite")
        }
        do {
            let store = try ShotDeckStore(url: url)
            let model = PlannerModel(
                projects: try store.allProjects(),
                scenes: try store.allScenes(),
                shots: try store.allShots()
            )
            return (store, model, nil)
        } catch {
            // Degrade honestly: work in memory, but never hide the failure.
            return (nil, PlannerModel(projects: [], scenes: [], shots: []),
                    "Local store unavailable: \(error.localizedDescription). Edits stay in memory only.")
        }
    }

    // MARK: - Queries

    var projects: [Project] { model.projects }

    func project(_ id: ProjectID) -> Project? { model.project(id) }

    func scene(_ id: SceneID) -> ShotDeckKit.Scene? { model.scene(id) }
    func shot(_ id: ShotID) -> Shot? { model.shot(id) }
    func scenes(in projectID: ProjectID) -> [ShotDeckKit.Scene] { model.scenes(in: projectID) }
    func shots(in sceneID: SceneID) -> [Shot] { model.shots(in: sceneID) }

    /// No cached green status: each query reads the actual ledger and checks.
    /// A missing/unreadable database stays unknown, never "not started".
    func coverage(for shot: Shot) -> CoverageSummary {
        _ = shootRevision
        guard let persistence,
              let ledger = try? persistence.takeLedger(for: shot.id),
              let checks = try? persistence.continuityChecks(for: shot.id) else {
            return CoverageEngine.derive(shot: shot, ledger: nil, continuityChecks: nil)
        }
        return CoverageEngine.derive(shot: shot, ledger: ledger, continuityChecks: checks)
    }

    func session(in projectID: ProjectID) -> ShootSessionContext {
        _ = shootRevision
        guard let persistence,
              let events = try? persistence.sessionEvents(in: projectID) else { return .unresolved }
        return .restore(events, validShotIDs: Set(model.allShots(in: projectID).map(\.id)))
    }

    func ledger(for shotID: ShotID) throws -> TakeLedger {
        _ = shootRevision
        return try requireStore().takeLedger(for: shotID)
    }

    func continuity(for shotID: ShotID) throws -> [ContinuityCheck] {
        _ = shootRevision
        return try requireStore().continuityChecks(for: shotID)
    }

    private func requireStore() throws -> ShotDeckStore {
        guard let persistence else {
            throw NSError(domain: "ShotDeck", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Local database unavailable; shoot changes were not saved."])
        }
        return persistence
    }

    func selectShot(_ shotID: ShotID, in projectID: ProjectID) throws {
        guard let shot = model.shot(shotID),
              model.allShots(in: projectID).contains(where: { $0.id == shotID }),
              shot.status != .omitted, shot.status != .archived else {
            throw PlannerValidationError.unknownShot(shotID)
        }
        let store = try requireStore()
        if session(in: projectID) == .inactive {
            try store.appendSessionEvent(SessionEvent(projectID: projectID, occurredAt: .now,
                                                      kind: .sessionStarted))
        }
        try store.appendSessionEvent(SessionEvent(projectID: projectID, occurredAt: .now,
                                                  kind: .shotSelected, shotID: shotID))
        shootRevision += 1
    }

    func endSession(in projectID: ProjectID) throws {
        try requireStore().appendSessionEvent(SessionEvent(projectID: projectID, occurredAt: .now,
                                                           kind: .sessionEnded))
        shootRevision += 1
    }

    func logTake(for shotID: ShotID, in projectID: ProjectID,
                 rating: TakeRating, notes: String,
                 durationSeconds: Double?, cameraDescription: String?) throws {
        guard session(in: projectID) == .active(shotID) else {
            throw PlannerValidationError.unknownShot(shotID)
        }
        if let durationSeconds, !durationSeconds.isFinite || durationSeconds <= 0 {
            throw NSError(domain: "ShotDeck", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Duration must be a positive number of seconds."])
        }
        // Time is known; camera is user-entered, not inferred from this device.
        let camera = cameraDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        let take = Take(shotID: shotID, recordedAt: .now, durationSeconds: durationSeconds,
                        cameraDescription: camera?.isEmpty == true ? nil : camera,
                        rating: rating, notes: notes)
        let event = SessionEvent(projectID: projectID, occurredAt: .now,
                                 kind: .takeAppended, shotID: shotID, takeID: take.id)
        try requireStore().appendTake(take, sessionEvent: event)
        shootRevision += 1
    }

    func chooseCandidate(_ takeID: TakeID, for shotID: ShotID, in projectID: ProjectID) throws {
        guard session(in: projectID) == .active(shotID) else {
            throw PlannerValidationError.unknownShot(shotID)
        }
        let event = SessionEvent(projectID: projectID, occurredAt: .now,
                                 kind: .candidateChanged, shotID: shotID, takeID: takeID)
        try requireStore().selectCandidate(takeID, for: shotID, event: event)
        shootRevision += 1
    }

    func addContinuity(to shotID: ShotID, label: String) throws {
        guard let shot = model.shot(shotID) else { throw PlannerValidationError.unknownShot(shotID) }
        let title = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PlannerValidationError.emptyTitle(entity: "Continuity check") }
        let check = ContinuityCheck(shotID: shotID, label: title)
        try requireStore().addRequiredContinuityCheck(check, to: shot)
        var edited = shot
        edited.requiredContinuityCheckIDs = (shot.requiredContinuityCheckIDs ?? []) + [check.id]
        try model.updateShot(edited)
        shootRevision += 1
    }

    func setContinuity(_ check: ContinuityCheck, status: ContinuityCheckStatus, notes: String) throws {
        var edited = check
        edited.status = status
        edited.notes = notes
        try requireStore().saveContinuityCheck(edited)
        shootRevision += 1
    }

    /// Reusable framing tags already used in the project (user-owned).
    func knownTags(in projectID: ProjectID) -> [String] { model.knownTags(in: projectID) }

    // MARK: - Mutations (persist first, then apply)

    func createProject(title: String) {
        let before = model
        model.createProject(title: title)
        commit(before) { store in
            try store.savePlannerDocument(
                projects: self.model.projects, scenes: self.model.scenes, shots: self.model.shots)
        }
    }

    func renameProject(_ id: ProjectID, title: String) throws {
        let before = model
        try model.renameProject(id, title: title)
        commit(before) { store in
            try store.savePlannerDocument(
                projects: self.model.projects, scenes: self.model.scenes, shots: self.model.shots)
        }
    }

    func setProjectStatus(_ id: ProjectID, status: ProjectStatus) throws {
        let before = model
        try model.setProjectStatus(id, status: status)
        commit(before) { store in
            try store.savePlannerDocument(
                projects: self.model.projects, scenes: self.model.scenes, shots: self.model.shots)
        }
    }

    func deleteProject(_ id: ProjectID) throws {
        let before = model
        try model.deleteProject(id)
        commit(before) { store in
            try store.deleteProject(id)
        }
    }

    func addScene(to projectID: ProjectID, title: String) throws {
        let before = model
        try model.addScene(to: projectID, title: title)
        commit(before) { store in
            try store.savePlannerDocument(
                projects: self.model.projects, scenes: self.model.scenes, shots: self.model.shots)
        }
    }

    func renameScene(_ id: SceneID, title: String) throws {
        let before = model
        try model.renameScene(id, title: title)
        commit(before) { store in
            try store.savePlannerDocument(
                projects: self.model.projects, scenes: self.model.scenes, shots: self.model.shots)
        }
    }

    func setSceneStatus(_ id: SceneID, status: SceneStatus) throws {
        let before = model
        try model.setSceneStatus(id, status: status)
        commit(before) { store in
            try store.savePlannerDocument(
                projects: self.model.projects, scenes: self.model.scenes, shots: self.model.shots)
        }
    }

    func moveScenes(in projectID: ProjectID, fromOffsets: IndexSet, toOffset destination: Int) throws {
        let before = model
        try model.moveScene(projectID, moving: fromOffsets, toDestination: destination)
        commit(before) { store in
            try store.savePlannerDocument(
                projects: self.model.projects, scenes: self.model.scenes, shots: self.model.shots)
        }
    }

    func deleteScene(_ id: SceneID) throws {
        let before = model
        try model.deleteScene(id)
        commit(before) { store in
            try store.deleteScene(id)
        }
    }

    func addShot(to sceneID: SceneID, title: String) throws {
        let before = model
        try model.addShot(to: sceneID, title: title)
        commit(before) { store in
            try store.savePlannerDocument(
                projects: self.model.projects, scenes: self.model.scenes, shots: self.model.shots)
        }
    }

    func updateShot(_ shot: Shot) throws {
        let before = model
        try model.updateShot(shot)
        commit(before) { store in
            try store.savePlannerDocument(
                projects: self.model.projects, scenes: self.model.scenes, shots: self.model.shots)
        }
    }

    func setShotStatus(_ id: ShotID, status: ShotStatus) throws {
        let before = model
        try model.setShotStatus(id, status: status)
        commit(before) { store in
            try store.savePlannerDocument(
                projects: self.model.projects, scenes: self.model.scenes, shots: self.model.shots)
        }
    }

    func moveShots(in sceneID: SceneID, fromOffsets: IndexSet, toOffset destination: Int) throws {
        let before = model
        try model.moveShot(sceneID, moving: fromOffsets, toDestination: destination)
        commit(before) { store in
            try store.savePlannerDocument(
                projects: self.model.projects, scenes: self.model.scenes, shots: self.model.shots)
        }
    }

    func deleteShot(_ id: ShotID) throws {
        let before = model
        try model.deleteShot(id)
        commit(before) { store in
            try store.deleteShot(id)
        }
    }

    /// Runs the persistence step for a model mutation that already happened.
    /// On failure the model is rolled back to `before` and the issue is
    /// surfaced — the UI never keeps changes the database refused.
    private func commit(_ before: PlannerModel, _ work: (ShotDeckStore) throws -> Void) {
        guard let persistence else { return }
        do {
            try work(persistence)
            persistenceIssue = nil
        } catch {
            model = before
            persistenceIssue = "Save failed, change reverted: \(error.localizedDescription)"
        }
    }
}
