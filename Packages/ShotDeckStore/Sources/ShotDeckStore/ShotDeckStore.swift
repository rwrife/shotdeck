import Foundation
import GRDB
import ShotDeckKit

/// Errors surfaced by store operations.
public enum StoreError: Error, Equatable, Sendable {
    case notFound(String)
    /// A take append would violate ledger rules (duplicate id, mixed shot,
    /// dangling/double revision) — enforced inside the write transaction.
    case ledger(TakeLedgerError)
    /// The store is at a schema version this build cannot read.
    case schemaTooNew(applied: [String], known: [String])
}

/// The durable local store: versioned migrations, ordered retrieval
/// repositories, and transactional write boundaries for shot/take mutations.
///
/// All writes go through `writer.write` so each mutation is a SQLite
/// transaction; multi-step operations (append take + session event) commit
/// atomically. The store never opens network sockets (enforced by the CI
/// zero-network gate).
public final class ShotDeckStore: Sendable {
    private let writer: any DatabaseWriter

    /// Open (and migrate) an in-memory store. Tests only.
    public init() throws {
        let queue = try DatabaseQueue()
        try Schema.fullMigrator().migrate(queue)
        self.writer = queue
    }

    /// Open (and migrate to the current schema) a file-backed store.
    public convenience init(url: URL) throws {
        try self.init(writer: DatabaseQueue(path: url.path))
    }

    private init(writer: any DatabaseWriter) throws {
        // Refuse to silently operate on a database written by a newer app
        // build instead of downgrading expectations. (A fresh database has
        // no grdb_migrations table yet.)
        let applied: [String] = try writer.read { db in
            guard try db.tableExists("grdb_migrations") else { return [] }
            return try String.fetchAll(
                db,
                sql: "SELECT identifier FROM grdb_migrations"
            )
        }
        let known: Set<String> = [Schema.migrationV1, Schema.migrationV2, Schema.migrationV3]
        if applied.contains(where: { !known.contains($0) }) {
            throw StoreError.schemaTooNew(applied: applied, known: Array(known).sorted())
        }
        try Schema.fullMigrator().migrate(writer)
        self.writer = writer
    }

    // MARK: - Planner document persistence (issue #4)

    /// Loose scene rows (position order across all projects) — used to
    /// rehydrate a `PlannerModel` alongside `allProjects()` / `allShots()`.
    public func allScenes() throws -> [Scene] {
        try writer.read { db in
            try SceneRecord.order(Column("position")).fetchAll(db).map { try $0.toDomain() }
        }
    }

    /// Loose shot rows (position order across all scenes).
    public func allShots() throws -> [Shot] {
        try writer.read { db in
            try ShotRecord.order(Column("position")).fetchAll(db).map { try $0.toDomain() }
        }
    }

    /// Upsert the whole planner document in one transaction: projects,
    /// scenes, and shots are written with the explicit positions the model
    /// currently holds. This is UPSERT-only — rows removed from the model
    /// are NOT deleted here; callers must apply the dedicated delete methods
    /// (deleteProject/deleteScene/deleteShot) so cascade intent stays
    /// explicit and take ledgers are never implicitly destroyed. Rewriting
    /// the dataset transactionally after each edit keeps the store and an
    /// observable app model from disagreeing while a persistence slice owns
    /// app-side loading (issue #5 wires crash-safe restore).
    public func savePlannerDocument(projects: [Project], scenes: [Scene], shots: [Shot]) throws {
        try writer.write { db in
            for (offset, project) in projects.enumerated() {
                var record = try ProjectRecord.from(domain: project, position: Int64(offset))
                try record.save(db)
            }
            for scene in scenes {
                let position = try Self.scenePosition(scene, projects: projects)
                var record = try SceneRecord.from(domain: scene, position: position)
                try record.save(db)
            }
            for shot in shots {
                let position = try Self.shotPosition(shot, scenes: scenes)
                var record = try ShotRecord.from(domain: shot, position: position)
                try record.save(db)
            }
        }
    }

    private static func scenePosition(_ scene: Scene, projects: [Project]) throws -> Int64 {
        guard let project = projects.first(where: { $0.id == scene.projectID }) else { return 0 }
        return Int64(project.sceneIDs.firstIndex(of: scene.id) ?? 0)
    }

    private static func shotPosition(_ shot: Shot, scenes: [Scene]) throws -> Int64 {
        guard let scene = scenes.first(where: { $0.id == shot.sceneID }) else { return 0 }
        return Int64(scene.shotIDs.firstIndex(of: shot.id) ?? 0)
    }

    // MARK: - Schema introspection

    /// Schema migration identifiers currently recorded in this database,
    /// in application order (reads GRDB's internal `grdb_migrations` table).
    public func appliedMigrations() throws -> [String] {
        try writer.read { db in
            guard try db.tableExists("grdb_migrations") else { return [] }
            return try String.fetchAll(
                db,
                sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
            )
        }
    }

    public func schemaVersion() throws -> Int {
        try writer.read { db in
            guard try db.tableExists("grdb_migrations") else { return 0 }
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM grdb_migrations"
            ) ?? 0
        }
    }

    /// Run pending migrations explicitly (also runs on open).
    public func migrate() throws {
        try Schema.fullMigrator().migrate(writer)
    }

    /// Escape hatch for tests/verification scripts: one read transaction.
    public func read<T>(_ block: @escaping (Database) throws -> T) throws -> T {
        try writer.read(block)
    }

    /// Escape hatch: one write transaction.
    public func write<T>(_ block: @escaping (Database) throws -> T) throws -> T {
        try writer.write(block)
    }

    // MARK: - Projects

    public func project(_ id: ProjectID) throws -> Project {
        try writer.read { db in
            guard let record: ProjectRecord = try ProjectRecord
                .filter(Column("id") == uuidText(id.rawValue))
                .fetchOne(db)
            else { throw StoreError.notFound("project \(id.rawValue)") }
            return try record.toDomain()
        }
    }

    /// Projects ordered by explicit position, tie-broken by the stable
    /// sort key (insertion-stable, pre-v3 compatible).
    public func allProjects() throws -> [Project] {
        try writer.read { db in
            try ProjectRecord
                .order(Column("position"), Column("sort_key"))
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    public func saveProject(_ project: Project) throws {
        try saveProject(project, position: 0)
    }

    public func saveProject(_ project: Project, position: Int64) throws {
        try writer.write { db in
            let existingPosition: Int64? = try Int64.fetchOne(
                db,
                sql: "SELECT position FROM project WHERE id = ?",
                arguments: [uuidText(project.id.rawValue)]
            )
            var record = try ProjectRecord.from(domain: project, position: existingPosition ?? position)
            try record.save(db)
        }
    }

    /// Atomically rewrite project list positions to the given order.
    public func setProjectOrder(_ projectIDs: [ProjectID]) throws {
        try writer.write { db in
            for (offset, projectID) in projectIDs.enumerated() {
                let key = uuidText(projectID.rawValue)
                guard try ProjectRecord.filter(Column("id") == key).fetchOne(db) != nil else {
                    throw StoreError.notFound("project \(projectID.rawValue)")
                }
                try ProjectRecord.filter(Column("id") == key)
                    .updateAll(db, Column("position").set(to: Int64(offset)))
            }
        }
    }

    /// Deletes the project row and its scene/shot document rows in one
    /// transaction (planner cascade). Take ledgers are append-only evidence
    /// and are never touched here — deleting a plan does not erase history.
    public func deleteProject(_ id: ProjectID) throws {
        try writer.write { db in
            guard try ProjectRecord.filter(Column("id") == uuidText(id.rawValue)).fetchOne(db) != nil
            else { throw StoreError.notFound("project \(id.rawValue)") }
            if let record: ProjectRecord = try ProjectRecord
                .filter(Column("id") == uuidText(id.rawValue))
                .fetchOne(db)
            {
                let project = try record.toDomain()
                for sceneID in project.sceneIDs {
                    // Tolerant cascade: a listed-but-missing scene row is a
                    // dangling id — skip it, never fail the user's delete.
                    _ = try Self.deleteSceneRowsTransaction(db, id: sceneID)
                }
            }
            _ = try ProjectRecord.filter(Column("id") == uuidText(id.rawValue)).deleteAll(db)
        }
    }

    /// Deletes the scene row and its shot document rows (planner cascade);
    /// take history is preserved.
    public func deleteScene(_ id: SceneID) throws {
        try writer.write { db in
            let deleted = try Self.deleteSceneRowsTransaction(db, id: id)
            guard deleted else { throw StoreError.notFound("scene \(id.rawValue)") }
        }
    }

    @discardableResult
    private static func deleteSceneRowsTransaction(_ db: Database, id: SceneID) throws -> Bool {
        guard let record: SceneRecord = try SceneRecord
            .filter(Column("id") == uuidText(id.rawValue))
            .fetchOne(db)
        else { return false }
        let scene = try record.toDomain()
        for shotID in scene.shotIDs {
            _ = try ShotRecord.filter(Column("id") == uuidText(shotID.rawValue)).deleteAll(db)
        }
        _ = try SceneRecord.filter(Column("id") == uuidText(id.rawValue)).deleteAll(db)
        return true
    }

    /// Deletes one shot document row; take history is preserved.
    public func deleteShot(_ id: ShotID) throws {
        try writer.write { db in
            let deleted = try ShotRecord.filter(Column("id") == uuidText(id.rawValue)).deleteAll(db)
            guard deleted > 0 else { throw StoreError.notFound("shot \(id.rawValue)") }
        }
    }

    // MARK: - Scenes (ordered by explicit position)

    /// Insert or update a scene plus its position in the project order.
    /// Reordering uses `setSceneOrder`, never implicit re-sorting.
    public func saveScene(_ scene: Scene, position: Int64) throws {
        try writer.write { db in
            var record = try SceneRecord.from(domain: scene, position: position)
            try record.save(db)
        }
    }

    public func scene(_ id: SceneID) throws -> Scene {
        try writer.read { db in
            guard let record: SceneRecord = try SceneRecord
                .filter(Column("id") == uuidText(id.rawValue))
                .fetchOne(db)
            else { throw StoreError.notFound("scene \(id.rawValue)") }
            return try record.toDomain()
        }
    }

    public func scenes(in projectID: ProjectID, ordered: Bool = true) throws -> [Scene] {
        try writer.read { db in
            var request = SceneRecord.filter(Column("project_id") == uuidText(projectID.rawValue))
            if ordered { request = request.order(Column("position")) }
            return try request.fetchAll(db).map { try $0.toDomain() }
        }
    }

    /// Atomically rewrite scene positions for a project to the given order.
    public func setSceneOrder(projectID: ProjectID, sceneIDs: [SceneID]) throws {
        try writer.write { db in
            for (offset, sceneID) in sceneIDs.enumerated() {
                let key = uuidText(sceneID.rawValue)
                guard try SceneRecord.filter(Column("id") == key).fetchOne(db) != nil else {
                    throw StoreError.notFound("scene \(sceneID.rawValue)")
                }
                try SceneRecord.filter(Column("id") == key)
                    .updateAll(db, Column("position").set(to: Int64(offset)))
            }
        }
    }

    // MARK: - Shots (ordered by explicit position)

    public func saveShot(_ shot: Shot, position: Int64) throws {
        try writer.write { db in
            var record = try ShotRecord.from(domain: shot, position: position)
            try record.save(db)
        }
    }

    public func shot(_ id: ShotID) throws -> Shot {
        try writer.read { db in
            guard let record: ShotRecord = try ShotRecord
                .filter(Column("id") == uuidText(id.rawValue))
                .fetchOne(db)
            else { throw StoreError.notFound("shot \(id.rawValue)") }
            return try record.toDomain()
        }
    }

    public func shots(in sceneID: SceneID, ordered: Bool = true) throws -> [Shot] {
        try writer.read { db in
            var request = ShotRecord.filter(Column("scene_id") == uuidText(sceneID.rawValue))
            if ordered { request = request.order(Column("position")) }
            return try request.fetchAll(db).map { try $0.toDomain() }
        }
    }

    public func setShotOrder(sceneID: SceneID, shotIDs: [ShotID]) throws {
        try writer.write { db in
            for (offset, shotID) in shotIDs.enumerated() {
                let key = uuidText(shotID.rawValue)
                guard try ShotRecord.filter(Column("id") == key).fetchOne(db) != nil else {
                    throw StoreError.notFound("shot \(shotID.rawValue)")
                }
                try ShotRecord.filter(Column("id") == key)
                    .updateAll(db, Column("position").set(to: Int64(offset)))
            }
        }
    }

    // MARK: - Takes (append-only ledger, transactional)

    /// Append one take to its shot's ledger inside a single transaction.
    /// Ledger validity (duplicate ids, revision chains) is re-checked
    /// against the persisted ledger, so concurrent processes cannot append
    /// an invalid revision chain.
    public func appendTake(_ take: Take) throws {
        try writer.write { db in
            var ledger = try Self.ledgerTransaction(db, shotID: take.shotID)
            do {
                try ledger.append(take)
            } catch let error as TakeLedgerError {
                throw StoreError.ledger(error)
            }
            let seq = Int64(ledger.entries.count)
            var takeRecord = try TakeRecord.from(domain: take, seq: seq)
            try takeRecord.insert(db)
        }
    }

    /// Append a take and record the matching session event atomically —
    /// both rows commit or neither does.
    public func appendTake(_ take: Take, sessionEvent: SessionEvent) throws {
        try writer.write { db in
            var ledger = try Self.ledgerTransaction(db, shotID: take.shotID)
            do {
                try ledger.append(take)
            } catch let error as TakeLedgerError {
                throw StoreError.ledger(error)
            }
            let seq = Int64(ledger.entries.count)
            var takeRecord = try TakeRecord.from(domain: take, seq: seq)
            try takeRecord.insert(db)
            var eventRecord = try SessionEventRecord.from(domain: sessionEvent)
            try eventRecord.insert(db)
        }
    }

    /// Rebuild the persisted take ledger for one shot (append order via seq).
    public func takeLedger(for shotID: ShotID) throws -> TakeLedger {
        try writer.read { db in try Self.ledgerTransaction(db, shotID: shotID) }
    }

    private static func ledgerTransaction(_ db: Database, shotID: ShotID) throws -> TakeLedger {
        let records: [TakeRecord] = try TakeRecord
            .filter(Column("shot_id") == uuidText(shotID.rawValue))
            .order(Column("seq"))
            .fetchAll(db)
        let takes = try records.map { try $0.toDomain() }
        do {
            var selection = try candidateSelectionTransaction(db, shotID: shotID)
            // The selection column may point at a take superseded later;
            // TakeLedger re-validates, so degrade to unknown rather than
            // fabricating a valid pointer.
            if case let .selected(candidateID) = selection,
               !takes.contains(where: { $0.id == candidateID }) {
                selection = .unknown
            }
            return try TakeLedger(entries: takes, candidateSelection: selection)
        } catch let error as TakeLedgerError {
            throw StoreError.ledger(error)
        }
    }

    // MARK: - Candidate selection (explicit, nullable)

    public func candidateSelection(for shotID: ShotID) throws -> CandidateTakeSelection {
        try writer.read { db in try Self.candidateSelectionTransaction(db, shotID: shotID) }
    }

    public func setCandidateSelection(_ selection: CandidateTakeSelection, for shotID: ShotID) throws {
        try writer.write { db in
            let kind: String
            let takeID: String?
            switch selection {
            case .unresolved:
                kind = "unresolved"; takeID = nil
            case .unknown:
                kind = "unknown"; takeID = nil
            case let .selected(id):
                kind = "selected"
                takeID = uuidText(id.rawValue)
                guard try TakeRecord.filter(Column("id") == takeID!).fetchOne(db) != nil else {
                    throw StoreError.ledger(TakeLedgerError.candidateTakeMissing(id))
                }
            }
            var candidate = ShotCandidateRecord(
                shot_id: uuidText(shotID.rawValue),
                selection_kind: kind,
                take_id: takeID
            )
            try candidate.save(db)
        }
    }

    private static func candidateSelectionTransaction(
        _ db: Database, shotID: ShotID
    ) throws -> CandidateTakeSelection {
        guard let row: ShotCandidateRecord = try ShotCandidateRecord
            .filter(Column("shot_id") == uuidText(shotID.rawValue))
            .fetchOne(db)
        else { return .unresolved }
        switch row.selection_kind {
        case "unresolved": return .unresolved
        case "unknown": return .unknown
        case "selected":
            guard let take = row.take_id, let uuid = UUID(uuidString: take) else {
                return .unknown
            }
            return .selected(TakeID(rawValue: uuid))
        default: return .unknown
        }
    }

    // MARK: - Continuity checks

    public func saveContinuityCheck(_ check: ContinuityCheck) throws {
        try writer.write { db in
            var record = try ContinuityCheckRecord.from(domain: check)
            try record.save(db)
        }
    }

    public func continuityChecks(for shotID: ShotID) throws -> [ContinuityCheck] {
        try writer.read { db in
            try ContinuityCheckRecord
                .filter(Column("shot_id") == uuidText(shotID.rawValue))
                .order(Column("id"))
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    // MARK: - Session events (append-only)

    public func appendSessionEvent(_ event: SessionEvent) throws {
        try writer.write { db in
            var record = try SessionEventRecord.from(domain: event)
            try record.insert(db)
        }
    }

    public func sessionEvents(in projectID: ProjectID) throws -> [SessionEvent] {
        try writer.read { db in
            try SessionEventRecord
                .filter(Column("project_id") == uuidText(projectID.rawValue))
                .order(Column("occurred_at"), Column("id"))
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    // MARK: - Full-dataset snapshot (for backup + verification tools)

    /// A complete lossless snapshot of the store contents.
    public struct Snapshot: Equatable, Sendable {
        public var projects: [Project]
        public var scenes: [Scene]
        public var shots: [Shot]
        public var ledgers: [(ShotID, TakeLedger)]
        public var continuityChecks: [ContinuityCheck]
        public var sessionEvents: [SessionEvent]

        public init(
            projects: [Project], scenes: [Scene], shots: [Shot],
            ledgers: [(ShotID, TakeLedger)], continuityChecks: [ContinuityCheck],
            sessionEvents: [SessionEvent]
        ) {
            self.projects = projects
            self.scenes = scenes
            self.shots = shots
            self.ledgers = ledgers
            self.continuityChecks = continuityChecks
            self.sessionEvents = sessionEvents
        }

        public static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.projects == rhs.projects
                && lhs.scenes == rhs.scenes
                && lhs.shots == rhs.shots
                && lhs.ledgers.map(\.1) == rhs.ledgers.map(\.1)
                && lhs.ledgers.map(\.0) == rhs.ledgers.map(\.0)
                && lhs.continuityChecks == rhs.continuityChecks
                && lhs.sessionEvents == rhs.sessionEvents
        }
    }

    public func snapshot() throws -> Snapshot {
        try writer.read { db in
            let projects = try ProjectRecord.order(Column("position"), Column("sort_key")).fetchAll(db)
                .map { try $0.toDomain() }
            let scenes = try SceneRecord.order(Column("position")).fetchAll(db)
                .map { try $0.toDomain() }
            let shotRecords = try ShotRecord.order(Column("position")).fetchAll(db)
            let shots = try shotRecords.map { try $0.toDomain() }
            var ledgers: [(ShotID, TakeLedger)] = []
            for shot in shots {
                ledgers.append((shot.id, try Self.ledgerTransaction(db, shotID: shot.id)))
            }
            let checks = try ContinuityCheckRecord.order(Column("id")).fetchAll(db)
                .map { try $0.toDomain() }
            let events = try SessionEventRecord
                .order(Column("occurred_at"), Column("id"))
                .fetchAll(db)
                .map { try $0.toDomain() }
            return Snapshot(
                projects: projects, scenes: scenes, shots: shots,
                ledgers: ledgers, continuityChecks: checks, sessionEvents: events
            )
        }
    }
}
