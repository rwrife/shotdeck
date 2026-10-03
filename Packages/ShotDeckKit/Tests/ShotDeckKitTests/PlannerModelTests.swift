import Foundation
import Testing
@testable import ShotDeckKit

/// Planner document model tests (issue #4). These exercise every planner
/// mutation on any Swift platform — the app target is a thin presentation
/// seam over this model.
@Suite("Planner model")
struct PlannerModelTests {
    private func ids(_ seed: UInt8) -> [UUID] {
        (0...6).map { byte in
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", Int(seed) * 16 + Int(byte)))!
        }
    }

    private func makeModel() -> PlannerModel {
        let u = ids(0xA)
        let project = Project(
            id: ProjectID(rawValue: u[0]), title: "Doc", status: .active,
            sceneIDs: [SceneID(rawValue: u[1]), SceneID(rawValue: u[2])]
        )
        let sceneA = Scene(
            id: SceneID(rawValue: u[1]), projectID: project.id, title: "A",
            shotIDs: [ShotID(rawValue: u[3]), ShotID(rawValue: u[4]), ShotID(rawValue: u[5])]
        )
        let sceneB = Scene(id: SceneID(rawValue: u[2]), projectID: project.id, title: "B")
        let shot1 = Shot(id: ShotID(rawValue: u[3]), sceneID: sceneA.id, title: "Wide")
        let shot2 = Shot(id: ShotID(rawValue: u[4]), sceneID: sceneA.id, title: "Tight")
        let shot3 = Shot(id: ShotID(rawValue: u[5]), sceneID: sceneA.id, title: "Insert")
        return PlannerModel(projects: [project], scenes: [sceneA, sceneB], shots: [shot1, shot2, shot3])
    }

    @Test("ordered reads follow the explicit id lists")
    func orderedReads() throws {
        let model = makeModel()
        let project = try #require(model.projects.first)
        #expect(model.scenes(in: project.id).map(\.title) == ["A", "B"])
        let sceneA = try #require(model.scenes(in: project.id).first)
        #expect(model.shots(in: sceneA.id).map(\.title) == ["Wide", "Tight", "Insert"])
        #expect(model.allShots(in: project.id).count == 3)
    }

    @Test("create/rename project keeps titles trimmed and rejects empties")
    func projectBasics() throws {
        var model = PlannerModel(projects: [], scenes: [], shots: [])
        model.createProject(title: "  Short Film  ")
        var project = try #require(model.projects.first)
        #expect(project.title == "Short Film")

        model.createProject(title: "   ")
        #expect(model.projects[1].title == "Untitled project")

        #expect(throws: PlannerValidationError.emptyTitle(entity: "Project")) {
            try model.renameProject(project.id, title: "  ")
        }
        try model.renameProject(project.id, title: "Renamed")
        project = try #require(model.project(project.id))
        #expect(project.title == "Renamed")

        let ghost = ProjectID()
        #expect(throws: PlannerValidationError.unknownProject(ghost)) {
            try model.renameProject(ghost, title: "Nope")
        }
    }

    @Test("scene CRUD: add appends, rename validates, delete cascades shots")
    func sceneCRUD() throws {
        var model = makeModel()
        let project = try #require(model.projects.first)
        try model.addScene(to: project.id, title: " C ")
        #expect(model.scenes(in: project.id).map(\.title) == ["A", "B", "C"])

        let sceneA = try #require(model.scenes(in: project.id).first)
        let sceneAID = sceneA.id
        try model.renameScene(sceneAID, title: "A renamed")
        #expect(model.scene(sceneAID)?.title == "A renamed")

        #expect(throws: PlannerValidationError.emptyTitle(entity: "Scene")) {
            try model.renameScene(sceneAID, title: "   ")
        }

        try model.deleteScene(sceneAID)
        #expect(model.scene(sceneAID) == nil)
        // Cascade: its three shots are gone from the dictionary.
        #expect(model.shots(in: sceneAID).isEmpty)
        let remaining = model.scenes(in: project.id)
        #expect(remaining.map(\.title) == ["B", "C"])  // C added earlier survives
        // Project scene list no longer references the deleted scene.
        let updated = try #require(model.project(project.id))
        #expect(!updated.sceneIDs.contains(sceneAID))
    }

    @Test("shot CRUD: add appends, status updates persist, delete unlists")
    func shotCRUD() throws {
        var model = makeModel()
        let project = try #require(model.projects.first)
        let sceneA = try #require(model.scenes(in: project.id).first)

        try model.addShot(to: sceneA.id, title: " Fourth ")
        #expect(model.shots(in: sceneA.id).map(\.title) == ["Wide", "Tight", "Insert", "Fourth"])

        let wide = try #require(model.shots(in: sceneA.id).first)
        try model.setShotStatus(wide.id, status: .omitted)
        #expect(model.shot(wide.id)?.status == .omitted)

        let ghostShotID = ShotID()
        #expect(throws: PlannerValidationError.unknownShot(ghostShotID)) {
            try model.setShotStatus(ghostShotID, status: .active)
        }

        try model.deleteShot(wide.id)
        #expect(model.shot(wide.id) == nil)
        let sceneAfter = try #require(model.scene(sceneA.id))
        #expect(!sceneAfter.shotIDs.contains(wide.id))
        _ = project
    }

    @Test("updateShot trims and normalizes every planner field")
    func shotNormalization() throws {
        var model = makeModel()
        let project = try #require(model.projects.first)
        let sceneA = try #require(model.scenes(in: project.id).first)
        var shot = try #require(model.shots(in: sceneA.id).first)

        shot.title = "  Trimmed title  "
        shot.framingTags = [" wide ", "", "wide", "slow mo", "  "]
        shot.lensDescription = "  "
        shot.actionNotes = "  notes  "
        shot.referenceFilename = "  frame01.png  "
        shot.referenceCaption = "   "
        try model.updateShot(shot)

        let stored = try #require(model.shot(shot.id))
        #expect(stored.title == "Trimmed title")
        #expect(stored.framingTags == ["wide", "slow mo"])  // trim + dedupe, order kept
        #expect(stored.lensDescription == nil)              // whitespace-only -> absence
        #expect(stored.actionNotes == "notes")
        #expect(stored.referenceFilename == "frame01.png")
        #expect(stored.referenceCaption == nil)
        _ = project
    }

    @Test("updateShot rejects empty titles and path-traversal reference names")
    func shotValidation() throws {
        var model = makeModel()
        let project = try #require(model.projects.first)
        let sceneA = try #require(model.scenes(in: project.id).first)
        var shot = try #require(model.shots(in: sceneA.id).first)

        shot.title = "   "
        #expect(throws: PlannerValidationError.emptyTitle(entity: "Shot")) {
            try model.updateShot(shot)
        }
        shot.title = "ok"

        for bad in ["../secret.png", "sub/dir.png", "..", "."] {
            shot.referenceFilename = bad
            #expect(throws: PlannerValidationError.invalidReferenceFilename(bad)) {
                try model.updateShot(shot)
            }
        }
        _ = project
    }

    @Test("scene and shot moves produce explicit reordered id lists")
    func moves() throws {
        var model = makeModel()
        let project = try #require(model.projects.first)
        let sceneA = try #require(model.scenes(in: project.id).first)

        // Move first shot to the end.
        try model.moveShot(sceneA.id, moving: IndexSet(integer: 0), toDestination: 3)
        #expect(model.shots(in: sceneA.id).map(\.title) == ["Tight", "Insert", "Wide"])

        // Move last scene to the front.
        try model.moveScene(project.id, moving: IndexSet(integer: 1), toDestination: 0)
        #expect(model.scenes(in: project.id).map(\.title) == ["B", "A"])

        // Out-of-range indices clamp without crashing or fabricating.
        try model.moveShot(sceneA.id, moving: IndexSet(integersIn: 0..<2), toDestination: 99)
        #expect(model.shots(in: sceneA.id).count == 3)
    }

    @Test("knownTags collects reusable tags in first-seen order")
    func knownTags() throws {
        var model = makeModel()
        let project = try #require(model.projects.first)
        let sceneA = try #require(model.scenes(in: project.id).first)
        var wide = try #require(model.shots(in: sceneA.id).first)
        wide.framingTags = ["wide", "dolly"]
        try model.updateShot(wide)
        var insert = model.shots(in: sceneA.id)[2]
        insert.framingTags = ["dolly", "macro"]
        try model.updateShot(insert)

        #expect(model.knownTags(in: project.id) == ["wide", "dolly", "macro"])
    }

    @Test("rebuilding from loose rows drops dangling ids, never fabricates")
    func danglingRepair() throws {
        let project = Project(title: "P", sceneIDs: [SceneID(rawValue: ids(0xB)[0]), SceneID(rawValue: ids(0xB)[1])])
        let scene = Scene(id: SceneID(rawValue: ids(0xB)[1]), projectID: project.id, title: "S",
                          shotIDs: [ShotID(rawValue: ids(0xB)[2]), ShotID(rawValue: ids(0xB)[3])])
        // scene[0] row missing, shot[2] row missing.
        let orphanShot = Shot(id: ShotID(rawValue: ids(0xB)[3]), sceneID: scene.id, title: "Only")
        let model = PlannerModel(projects: [project], scenes: [scene], shots: [orphanShot])

        let keptProject = try #require(model.project(project.id))
        #expect(keptProject.sceneIDs == [scene.id])  // dangling scene id dropped
        let keptScene = try #require(model.scene(scene.id))
        #expect(keptScene.shotIDs == [orphanShot.id])  // dangling shot id dropped
    }
}

@Suite("Planner coding")
struct PlannerCodingTests {
    @Test("Shot decodes pre-planner payloads with defaults")
    func legacyPayload() throws {
        // A payload shaped like the pre-issue-#4 encoder output.
        let json = """
        {"id":{"rawValue":"00000000-0000-4000-8000-000000000001"},\
        "sceneID":{"rawValue":"00000000-0000-4000-8000-000000000002"},\
        "title":"Legacy","status":"planned","requiredContinuityCheckIDs":[]}
        """
        let shot = try JSONDecoder().decode(Shot.self, from: Data(json.utf8))
        #expect(shot.framingTags == [])
        #expect(shot.lensDescription == nil)
        #expect(shot.orientation == nil)
        #expect(shot.movement == nil)
        #expect(shot.actionNotes == "")
        #expect(shot.referenceFilename == nil)
        #expect(shot.referenceCaption == nil)
    }

    @Test("unknown orientation/movement strings degrade to nil")
    func unknownEnumSafe() throws {
        let json = """
        {"id":{"rawValue":"00000000-0000-4000-8000-000000000001"},\
        "sceneID":{"rawValue":"00000000-0000-4000-8000-000000000002"},\
        "title":"Future","status":"planned","requiredContinuityCheckIDs":[],\
        "orientation":"hologram","movement":"warp"}
        """
        let shot = try JSONDecoder().decode(Shot.self, from: Data(json.utf8))
        #expect(shot.orientation == nil)
        #expect(shot.movement == nil)
        #expect(shot.title == "Future")
    }

    @Test("planner fields survive an encode/decode round trip")
    func roundTrip() throws {
        var shot = Shot(
            sceneID: SceneID(rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!),
            title: "Full", framingTags: ["wide"], lensDescription: "35mm",
            orientation: .portrait, movement: .pushIn, actionNotes: "notes",
            referenceFilename: "a.png", referenceCaption: "cap"
        )
        shot.requiredContinuityCheckIDs = nil
        let data = try JSONEncoder().encode(shot)
        #expect(try JSONDecoder().decode(Shot.self, from: data) == shot)
    }
}

@Suite("Coverage: archived shots")
struct ArchivedCoverageTests {
    @Test("archived derives omitted with the shot_archived reason")
    func archivedReason() {
        let shot = Shot(
            sceneID: SceneID(), title: "Pulled", status: .archived,
            requiredContinuityCheckIDs: []
        )
        let summary = CoverageEngine.derive(shot: shot, ledger: nil, continuityChecks: nil)
        #expect(summary.state == .omitted)
        #expect(summary.reasons == [.shotArchived])
    }

    @Test("omitted keeps its own reason so the two stay distinguishable")
    func omittedReason() {
        let shot = Shot(
            sceneID: SceneID(), title: "Skipped", status: .omitted,
            requiredContinuityCheckIDs: []
        )
        let summary = CoverageEngine.derive(shot: shot, ledger: nil, continuityChecks: nil)
        #expect(summary.state == .omitted)
        #expect(summary.reasons == [.explicitlyOmitted])
    }
}

@Suite("Status presentation")
struct StatusPresentationTests {
    @Test("every shot status has a distinct glyph and spoken label")
    func shotStatusDistinct() {
        let glyphs = Set(ShotStatus.allCases.map(StatusGlyph.shot))
        #expect(glyphs.count == ShotStatus.allCases.count)
        for status in ShotStatus.allCases {
            #expect(StatusCopy.shot(status).hasPrefix("Shot status:"))
        }
    }

    @Test("coverage copy names reasons for unknown-safe review")
    func coverageCopy() throws {
        let shot = Shot(sceneID: SceneID(), title: "T", status: .planned, requiredContinuityCheckIDs: nil)
        let candidate = Take(
            shotID: shot.id, recordedAt: Date(timeIntervalSince1970: 1),
            durationSeconds: 3, cameraDescription: "A-cam"
        )
        var ledger = try TakeLedger(entries: [candidate])
        try ledger.selectCandidate(candidate.id)
        let summary = CoverageEngine.derive(shot: shot, ledger: ledger, continuityChecks: nil)
        #expect(summary.state == .unknown)
        #expect(summary.reasons == [.continuityRequirementsUnavailable])
        let copy = StatusCopy.coverage(summary)
        #expect(copy.contains("Coverage: unknown"))
        #expect(copy.contains("continuity_requirements_unavailable"))
    }

    @Test("missing coverage copy is explicit, never optimistic")
    func missingCoverage() {
        #expect(StatusCopy.coverage(nil) == "Coverage: unknown (not yet derived)")
    }
}
