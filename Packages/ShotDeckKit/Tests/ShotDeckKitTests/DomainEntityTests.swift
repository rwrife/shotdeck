import Foundation
import Testing
@testable import ShotDeckKit

@Suite("Domain entities")
struct DomainEntityTests {
    @Test("entities have stable IDs and explicit status enums")
    func entitiesHaveStableShape() {
        let project = Project(
            id: ProjectID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!),
            title: "Doc Short",
            status: .active,
            sceneIDs: [SceneID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000902")!)]
        )

        let scene = Scene(
            id: SceneID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000902")!),
            projectID: project.id,
            title: "Kitchen",
            status: .planned,
            shotIDs: [ShotID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000903")!)]
        )

        let shot = Shot(
            id: ShotID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000903")!),
            sceneID: scene.id,
            title: "Insert",
            status: .active,
            requiredContinuityCheckIDs: []
        )

        let continuity = ContinuityCheck(
            id: ContinuityCheckID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000904")!),
            shotID: shot.id,
            label: "Cup handle points left",
            status: .pending
        )

        #expect(project.status == .active)
        #expect(scene.status == .planned)
        #expect(shot.status == .active)
        #expect(continuity.status == .pending)

        #expect(CoverageState.notStarted.rawValue == "not_started")
        #expect(CoverageState.candidateSelected.rawValue == "candidate_selected")
        #expect(CoverageReason.explicitlyOmitted.rawValue == "explicitly_omitted")
    }

    @Test("session event links project and optional shot/take references")
    func sessionEventShape() {
        let projectID = ProjectID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000910")!)
        let shotID = ShotID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000911")!)
        let takeID = TakeID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000912")!)

        let event = SessionEvent(
            projectID: projectID,
            occurredAt: Date(timeIntervalSince1970: 100),
            kind: .takeAppended,
            shotID: shotID,
            takeID: takeID
        )

        #expect(event.projectID == projectID)
        #expect(event.shotID == shotID)
        #expect(event.takeID == takeID)
        #expect(event.kind == .takeAppended)
    }
}
