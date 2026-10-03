import Foundation
import GRDB
import Testing
@testable import ShotDeckStore
import ShotDeckKit

/// Planner persistence tests (issue #4): v3 schema, planner metadata
/// round-trip, honest defaults for pre-v3 rows, and document save/load.
@Suite("Planner schema v3")
struct PlannerSchemaTests {
    @Test("fresh store records v1 + v2 + v3")
    func freshSchema() throws {
        let (store, _) = try TestSupport.makeStore(name: "v3-fresh")
        #expect(try store.appliedMigrations() == [
            Schema.migrationV1, Schema.migrationV2, Schema.migrationV3,
        ])
        #expect(try store.schemaVersion() == 3)
    }

    @Test("v1 fixture rows upgrade with honest planner defaults")
    func v1RowsUpgradeHonestly() throws {
        let (store, _) = try TestSupport.makeStore(name: "v3-upgrade")
        // Seed v1-era rows through the v1-only path, then upgrade the file.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shotdeck-v3-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture-v1.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try Fixture.seedV1(queue)

        let upgraded = try ShotDeckStore(url: url)
        // v1 shots decode with: no tags, no notes, no optional metadata —
        // never fabricated planner values.
        for shot in try upgraded.allShots() {
            #expect(shot.framingTags == [])
            #expect(shot.lensDescription == nil)
            #expect(shot.orientation == nil)
            #expect(shot.movement == nil)
            #expect(shot.actionNotes == "")
            #expect(shot.referenceFilename == nil)
            #expect(shot.referenceCaption == nil)
        }
        // The upgraded rows still match the fixture dataset exactly.
        #expect(try upgraded.allShots().map(\.id) == Fixture.shots().map(\.id))
    }

    @Test("full planner metadata round-trips through v3 columns")
    func plannerMetadataRoundTrip() throws {
        let (store, _) = try TestSupport.makeStore(name: "v3-roundtrip")
        let sceneID = SceneID()
        var shot = Shot(
            sceneID: sceneID, title: "Full",
            requiredContinuityCheckIDs: nil,
            framingTags: ["wide", "slow mo"], lensDescription: "35mm prime",
            orientation: .landscape, movement: .gimbal,
            actionNotes: "Talents cross screen left",
            referenceFilename: "frame01.png", referenceCaption: "Reference still"
        )
        try store.saveShot(shot, position: 4)
        var fetched = try store.shot(shot.id)
        #expect(fetched == shot)

        // Unknown enum strings in storage degrade to explicit absence.
        try store.write { db in
            try db.execute(
                sql: "UPDATE shot SET orientation = 'hologram', movement = 'warp' WHERE id = ?",
                arguments: [uuidText(shot.id.rawValue)]
            )
        }
        fetched = try store.shot(shot.id)
        #expect(fetched.orientation == nil)
        #expect(fetched.movement == nil)
        // The rest of the row is untouched by the unknown-safe decode.
        #expect(fetched.framingTags == ["wide", "slow mo"])
        #expect(fetched.lensDescription == "35mm prime")
    }

    @Test("project order is explicit and rewrites atomically")
    func projectOrdering() throws {
        let (store, _) = try TestSupport.makeStore(name: "v3-order")
        let p1 = Project(title: "One")
        let p2 = Project(title: "Two")
        let p3 = Project(title: "Three")
        for (offset, project) in [p1, p2, p3].enumerated() {
            try store.saveProject(project, position: Int64(offset))
        }
        #expect(try store.allProjects().map(\.id) == [p1.id, p2.id, p3.id])

        try store.setProjectOrder([p3.id, p1.id, p2.id])
        #expect(try store.allProjects().map(\.id) == [p3.id, p1.id, p2.id])

        // Re-saving a project keeps its stored position (no silent reorder).
        try store.saveProject(Project(id: p1.id, title: "One renamed"), position: 99)
        #expect(try store.allProjects().map(\.id) == [p3.id, p1.id, p2.id])
    }

    @Test("savePlannerDocument persists a whole model transactionally")
    func documentSaveLoad() throws {
        let (store, _) = try TestSupport.makeStore(name: "v3-document")
        let project = Project(
            title: "Trip", sceneIDs: [])
        var model = PlannerModel(projects: [project], scenes: [], shots: [])
        let scene = try model.addScene(to: project.id, title: "Harbor")
        _ = try model.addShot(to: scene.id, title: "Drone in")
        _ = try model.addShot(to: scene.id, title: "Master")
        let savedProject = model.project(project.id)!
        try store.savePlannerDocument(
            projects: model.projects, scenes: model.scenes, shots: model.shots)

        let loaded = PlannerModel(
            projects: try store.allProjects(),
            scenes: try store.allScenes(),
            shots: try store.allShots()
        )
        #expect(loaded.project(project.id)?.sceneIDs == savedProject.sceneIDs)
        #expect(loaded.shots(in: scene.id).map(\.title) == ["Drone in", "Master"])

        // A second save after a reorder persists the new order.
        try model.moveShot(scene.id, moving: IndexSet(integer: 1), toDestination: 0)
        try store.savePlannerDocument(
            projects: model.projects, scenes: model.scenes, shots: model.shots)
        let reloaded = PlannerModel(
            projects: try store.allProjects(),
            scenes: try store.allScenes(),
            shots: try store.allShots()
        )
        #expect(reloaded.shots(in: scene.id).map(\.title) == ["Master", "Drone in"])
    }

    @Test("store cascades planner deletes but never take history")
    func cascadeDeletes() throws {
        let (store, _) = try TestSupport.makeStore(name: "v3-cascade")
        let project = Fixture.projects()[0]
        try store.saveProject(project, position: 0)
        for (offset, scene) in Fixture.scenes().enumerated() {
            try store.saveScene(scene, position: Int64(offset))
        }
        for (offset, shot) in Fixture.shots().enumerated() {
            try store.saveShot(shot, position: Int64(offset))
        }
        try store.appendTake(Fixture.takes()[0])

        try store.deleteScene(Fixture.sceneIDA)
        // Shots under scene A gone; scene B's shot survives.
        #expect(try store.shots(in: Fixture.sceneIDA).isEmpty)
        #expect(try store.shots(in: Fixture.sceneIDB).count == 1)
        // Take ledger untouched by the plan delete.
        #expect(try store.takeLedger(for: Fixture.shotIDA1).entries.count == 1)

        try store.deleteProject(project.id)
        #expect(try store.allProjects().isEmpty)
        #expect(try store.allScenes().isEmpty)
        #expect(try store.allShots().isEmpty)
        #expect(try store.takeLedger(for: Fixture.shotIDA1).entries.count == 1)

        #expect(throws: StoreError.self) { try store.deleteScene(SceneID()) }
    }

    @Test("deleteProject cascades even with dangling listed ids")
    func cascadeWithDanglingIds() throws {
        let (store, _) = try TestSupport.makeStore(name: "v3-dangling")
        let ghostScene = SceneID()
        let project = Project(title: "P", sceneIDs: [ghostScene])
        try store.saveProject(project, position: 0)
        // The listed scene row is missing — delete must still succeed.
        try store.deleteProject(project.id)
        #expect(try store.allProjects().isEmpty)
    }
}
