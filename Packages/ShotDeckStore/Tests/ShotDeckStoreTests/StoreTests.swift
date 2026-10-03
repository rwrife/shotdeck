import Foundation
import GRDB
import Testing
@testable import ShotDeckStore
import ShotDeckKit

/// Shared helpers for store tests.
enum TestSupport {
    /// A fresh file-backed store in a unique temporary directory.
    static func makeStore(name: String) throws -> (ShotDeckStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shotdeck-store-tests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("shotdeck.sqlite")
        let store = try ShotDeckStore(url: url)
        return (store, url)
    }

    /// A v1-only-schema database seeded with the committed fixture dataset.
    static func makeSeededV1Queue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Fixture.seedV1(queue)
        return queue
    }
}

@Suite("Migration manager")
struct MigrationTests {
    @Test("fresh store migrates to current schema with named versions")
    func freshStoreSchema() throws {
        let (store, _) = try TestSupport.makeStore(name: "fresh")
        let applied = try store.appliedMigrations()
        #expect(applied == [Schema.migrationV1, Schema.migrationV2, Schema.migrationV3])
        #expect(try store.schemaVersion() == Schema.currentVersion)
    }

    @Test("v1 fixture database migrates to current schema on open")
    func v1DatabaseUpgrades() throws {
        let queue = try TestSupport.makeSeededV1Queue()
        let v1Applied = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(v1Applied == [Schema.migrationV1])

        // Writing the schema-v1 file then reopening through ShotDeckStore
        // exercises the real upgrade path.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shotdeck-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture-v1.sqlite")
        let fileQueue = try DatabaseQueue(path: url.path)
        try Fixture.seedV1(fileQueue)

        let upgraded = try ShotDeckStore(url: url)
        #expect(try upgraded.appliedMigrations() == [Schema.migrationV1, Schema.migrationV2, Schema.migrationV3])
        #expect(try upgraded.schemaVersion() == Schema.currentVersion)
    }

    @Test("store refuses a database from a newer schema")
    func refusesNewerSchema() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shotdeck-newer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("future.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        var migrator = Schema.fullMigrator()
        migrator.registerMigration("v3-future-feature") { db in
            try db.create(table: "future_table") { t in
                t.column("id", .integer).primaryKey()
            }
        }
        try migrator.migrate(queue)

        do {
            _ = try ShotDeckStore(url: url)
            Issue.record("expected schemaTooNew")
        } catch let error as StoreError {
            guard case .schemaTooNew = error else {
                Issue.record("expected schemaTooNew, got \(error)")
                return
            }
        }
    }
}

@Suite("Fixture lossless migration", .serialized)
struct FixtureLosslessTests {
    @Test("v1 fixture -> current schema is lossless for every entity")
    func fixtureMigratesLosslessly() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shotdeck-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Fixture.fixtureFileName)
        let queue = try DatabaseQueue(path: url.path)
        try Fixture.seedV1(queue)

        // Open through the store: applies v2 migration.
        let store = try ShotDeckStore(url: url)
        let snapshot = try store.snapshot()

        #expect(snapshot.projects == Fixture.projects())
        #expect(snapshot.scenes == Fixture.scenes())
        #expect(snapshot.shots == Fixture.shots())
        #expect(snapshot.continuityChecks == Fixture.continuityChecks())
        #expect(snapshot.sessionEvents == Fixture.sessionEvents())

        // v1 takes survive with v2 facts as explicit absence, never fabrications.
        let ledger = try store.takeLedger(for: Fixture.shotIDA1)
        #expect(ledger.entries == Fixture.takes())
        #expect(ledger.candidateSelection == .unresolved)

        // Unknown-safe shot: nil required_ids must decode back to nil.
        let b1 = try store.shot(Fixture.shotIDB1)
        #expect(b1.requiredContinuityCheckIDs == nil)
        // Explicitly-empty shot decodes to an empty array, not nil.
        let a2 = try store.shot(Fixture.shotIDA2)
        #expect(a2.requiredContinuityCheckIDs == [])
    }

    @Test("committed repo fixture verifies losslessly after migration")
    func committedFixtureMatchesCode() throws {
        // Resolve the committed fixture relative to the package checkout so
        // `swift test` proves the repo artifact, not a regenerated copy.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/ShotDeckStoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ShotDeckStore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repo root
        let fixtureURL = packageRoot
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(Fixture.fixtureFileName)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            Issue.record("committed fixture missing at \(fixtureURL.path)")
            return
        }
        // Never open the committed artifact in place — opening migrates.
        let scratchDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shotdeck-committed-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        let scratchURL = scratchDir.appendingPathComponent(Fixture.fixtureFileName)
        try FileManager.default.copyItem(at: fixtureURL, to: scratchURL)
        let store = try ShotDeckStore(url: scratchURL)
        #expect(try store.appliedMigrations() == [Schema.migrationV1, Schema.migrationV2, Schema.migrationV3])
        let snapshot = try store.snapshot()
        #expect(snapshot.projects == Fixture.projects())
        #expect(snapshot.scenes == Fixture.scenes())
        #expect(snapshot.shots == Fixture.shots())
        #expect(snapshot.continuityChecks == Fixture.continuityChecks())
        #expect(snapshot.sessionEvents == Fixture.sessionEvents())
        let ledger = try store.takeLedger(for: Fixture.shotIDA1)
        #expect(ledger.entries == Fixture.takes())
    }
}

@Suite("Repository round-trip")
struct RepositoryTests {
    @Test("projects, scenes, shots round-trip with explicit ordering")
    func orderedRoundTrip() throws {
        let (store, _) = try TestSupport.makeStore(name: "order")
        try store.saveProject(Fixture.projects()[0])
        for (offset, scene) in Fixture.scenes().enumerated() {
            try store.saveScene(scene, position: Int64(offset))
        }
        for (offset, shot) in Fixture.shots().enumerated() {
            try store.saveShot(shot, position: Int64(offset))
        }

        #expect(try store.project(Fixture.projectID) == Fixture.projects()[0])
        #expect(try store.scenes(in: Fixture.projectID) == Fixture.scenes())
        #expect(try store.shots(in: Fixture.sceneIDA) == [
            Fixture.shots()[0], Fixture.shots()[1],
        ])

        // Reorder scenes atomically; retrieval follows the new explicit order.
        try store.setSceneOrder(
            projectID: Fixture.projectID,
            sceneIDs: [Fixture.sceneIDB, Fixture.sceneIDA]
        )
        #expect(try store.scenes(in: Fixture.projectID) == [
            Fixture.scenes()[1], Fixture.scenes()[0],
        ])

        // Missing entity surfaces an explicit error, never a fabricated value.
        do {
            _ = try store.scene(SceneID())
            Issue.record("expected notFound")
        } catch let error as StoreError {
            guard case .notFound = error else {
                Issue.record("expected notFound, got \(error)")
                return
            }
        } catch {
            Issue.record("expected notFound, got \(error)")
        }
    }

    @Test("continuity checks and session events round-trip")
    func childEntities() throws {
        let (store, _) = try TestSupport.makeStore(name: "children")
        try store.saveProject(Fixture.projects()[0])
        for check in Fixture.continuityChecks() {
            try store.saveContinuityCheck(check)
        }
        #expect(try store.continuityChecks(for: Fixture.shotIDA1) == Fixture.continuityChecks())

        try store.appendSessionEvent(Fixture.sessionEvents()[0])
        try store.appendSessionEvent(Fixture.sessionEvents()[1])
        #expect(try store.sessionEvents(in: Fixture.projectID) == Fixture.sessionEvents())
    }
}

@Suite("Transactional take ledger")
struct TakeLedgerStoreTests {
    @Test("takes append in order and rebuild into a valid TakeLedger")
    func appendAndRebuild() throws {
        let (store, _) = try TestSupport.makeStore(name: "ledger")
        let shot = Fixture.shots()[0]
        try store.saveShot(shot, position: 0)
        try store.appendTake(Fixture.takes()[0])
        try store.appendTake(Fixture.takes()[1])
        let ledger = try store.takeLedger(for: Fixture.shotIDA1)
        #expect(ledger.entries == Fixture.takes())
    }

    @Test("duplicate take id is rejected inside the transaction")
    func duplicateRejected() throws {
        let (store, _) = try TestSupport.makeStore(name: "dup")
        try store.saveShot(Fixture.shots()[0], position: 0)
        try store.appendTake(Fixture.takes()[0])
        do {
            try store.appendTake(Fixture.takes()[0])
            Issue.record("expected duplicate rejection")
        } catch let error as StoreError {
            #expect(error == .ledger(.duplicateTakeID(Fixture.takeIDA1R1)))
        }
        // The rejected write left no partial row.
        #expect(try store.takeLedger(for: Fixture.shotIDA1).entries.count == 1)
    }

    @Test("revision chains persist with v2 columns and rebuild losslessly")
    func revisionChain() throws {
        let (store, _) = try TestSupport.makeStore(name: "revision")
        try store.saveShot(Fixture.shots()[0], position: 0)
        for take in Fixture.currentExtensionTakes() {
            try store.appendTake(take)
        }
        let ledger = try store.takeLedger(for: Fixture.shotIDA1)
        #expect(ledger.entries == Fixture.currentExtensionTakes())
        #expect(ledger.currentTakes == [Fixture.currentExtensionTakes()[1]])
        // Duration and revision_of survived the round trip.
        let revised = ledger.entries[1]
        #expect(revised.revisionOf == Fixture.takeIDA1R1)
        let original = ledger.entries[0]
        #expect(original.durationSeconds == 41.5)
    }

    @Test("append take + session event commits atomically")
    func atomicPair() throws {
        let (store, _) = try TestSupport.makeStore(name: "atomic")
        try store.saveProject(Fixture.projects()[0])
        try store.saveShot(Fixture.shots()[0], position: 0)
        let event = Fixture.sessionEvents()[1]
        let take = Fixture.currentExtensionTakes()[0]
        try store.appendTake(take, sessionEvent: event)
        #expect(try store.takeLedger(for: Fixture.shotIDA1).entries == [take])
        #expect(try store.sessionEvents(in: Fixture.projectID) == [event])

        // Same call with a duplicate take must roll back BOTH writes.
        do {
            try store.appendTake(take, sessionEvent: Fixture.sessionEvents()[0])
            Issue.record("expected duplicate rejection")
        } catch is StoreError {}
        #expect(try store.takeLedger(for: Fixture.shotIDA1).entries.count == 1)
        // The rolled-back event count proves transaction rollback.
        #expect(try store.sessionEvents(in: Fixture.projectID).count == 1)
    }
}

@Suite("Candidate selection")
struct CandidateSelectionTests {
    @Test("selection states round-trip: unresolved, selected, unknown")
    func selectionStates() throws {
        let (store, _) = try TestSupport.makeStore(name: "candidate")
        try store.saveShot(Fixture.shots()[0], position: 0)
        #expect(try store.candidateSelection(for: Fixture.shotIDA1) == .unresolved)

        let takes = Fixture.currentExtensionTakes()
        try store.appendTake(takes[0])
        try store.appendTake(takes[1])

        try store.setCandidateSelection(.selected(Fixture.takeIDA1R2), for: Fixture.shotIDA1)
        #expect(try store.candidateSelection(for: Fixture.shotIDA1) == .selected(Fixture.takeIDA1R2))

        try store.setCandidateSelection(.unknown, for: Fixture.shotIDA1)
        #expect(try store.candidateSelection(for: Fixture.shotIDA1) == .unknown)

        try store.setCandidateSelection(.unresolved, for: Fixture.shotIDA1)
        #expect(try store.candidateSelection(for: Fixture.shotIDA1) == .unresolved)
    }

    @Test("selecting a nonexistent take is refused")
    func missingCandidateRefused() throws {
        let (store, _) = try TestSupport.makeStore(name: "candidate-missing")
        try store.saveShot(Fixture.shots()[0], position: 0)
        do {
            try store.setCandidateSelection(.selected(TakeID()), for: Fixture.shotIDA1)
            Issue.record("expected candidateTakeMissing")
        } catch let error as StoreError {
            guard case .ledger(.candidateTakeMissing) = error else {
                Issue.record("expected candidateTakeMissing, got \(error)")
                return
            }
        }
    }
}
