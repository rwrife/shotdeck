import Foundation
import Testing
@testable import ShotDeckKit

@Suite("Shoot session restoration")
struct ShootSessionTests {
    @Test("start, select and end replay in append order without inventing context")
    func replay() {
        let project = ProjectID()
        let shot = ShotID()
        let timestamp = Date(timeIntervalSince1970: 123)
        let events = [
            SessionEvent(projectID: project, occurredAt: timestamp, kind: .sessionStarted),
            SessionEvent(projectID: project, occurredAt: timestamp, kind: .shotSelected, shotID: shot)
        ]
        #expect(ShootSessionContext.restore(events, validShotIDs: [shot]) == .active(shot))
        #expect(ShootSessionContext.restore(events + [
            SessionEvent(projectID: project, occurredAt: timestamp, kind: .sessionEnded)
        ], validShotIDs: [shot]) == .inactive)
        #expect(ShootSessionContext.restore(events, validShotIDs: []) == .unresolved)
        #expect(ShootSessionContext.restore([events[1]], validShotIDs: [shot]) == .unresolved)
    }

    @Test("unknown events and missing shot IDs cannot turn into active context")
    func unknownSafe() {
        let project = ProjectID()
        let event = SessionEvent(projectID: project, occurredAt: .now, kind: .unknown)
        #expect(ShootSessionContext.restore([event], validShotIDs: []) == .unresolved)
        #expect(ShootSessionContext.restore([], validShotIDs: []) == .inactive)
    }
}

@Suite("Duo layout seam")
struct ShootWorkspaceLayoutTests {
    @Test("folded is a single focus, unfolded keeps independent shot and ledger panels")
    func mapping() {
        #expect(ShootWorkspaceLayout(foldState: .folded).panels == [.activeShot])
        #expect(ShootWorkspaceLayout(foldState: .unfolded).panels == [.activeShot, .takeLedger])
        #expect(ShootWorkspaceLayout(foldState: .unknown).panels == [.activeShot])
    }
}
