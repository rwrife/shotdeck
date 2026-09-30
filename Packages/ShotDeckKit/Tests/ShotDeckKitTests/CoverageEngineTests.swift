import Foundation
import Testing
@testable import ShotDeckKit

@Suite("Coverage engine")
struct CoverageEngineTests {
    private let projectID = ProjectID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    private let sceneID = SceneID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    private let shotID = ShotID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    private let checkID = ContinuityCheckID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)

    @Test("coverage states are deterministic for core transitions")
    func tableDrivenTransitions() throws {
        let shot = Shot(id: shotID, sceneID: sceneID, title: "Close-up", status: .planned, requiredContinuityCheckIDs: [checkID])

        let take = makeTake(
            id: "00000000-0000-0000-0000-000000000111",
            recordedAt: date(1),
            camera: "A-Cam 35mm"
        )

        let continuity = ContinuityCheck(id: checkID, shotID: shotID, label: "Cup level", status: .matched)

        var noCandidateLedger = try TakeLedger(entries: [take], candidateSelection: .unresolved)
        var selectedLedger = noCandidateLedger
        try selectedLedger.selectCandidate(take.id)

        let cases: [Case] = [
            Case(
                name: "not started when no takes",
                shot: shot,
                ledger: try TakeLedger(entries: [], candidateSelection: .unresolved),
                checks: [continuity],
                expectedState: .notStarted,
                expectedReason: .noTakes
            ),
            Case(
                name: "attempted when takes exist but candidate unresolved",
                shot: shot,
                ledger: noCandidateLedger,
                checks: [continuity],
                expectedState: .attempted,
                expectedReason: .candidateNotSelected
            ),
            Case(
                name: "candidate selected when explicit candidate and continuity are valid",
                shot: shot,
                ledger: selectedLedger,
                checks: [continuity],
                expectedState: .candidateSelected,
                expectedReason: .explicitCandidateSelected
            ),
            Case(
                name: "omitted shot short-circuits to omitted",
                shot: Shot(id: shotID, sceneID: sceneID, title: "Close-up", status: .omitted, requiredContinuityCheckIDs: [checkID]),
                ledger: selectedLedger,
                checks: [continuity],
                expectedState: .omitted,
                expectedReason: .explicitlyOmitted
            )
        ]

        for testCase in cases {
            let summary = CoverageEngine.derive(
                shot: testCase.shot,
                ledger: testCase.ledger,
                continuityChecks: testCase.checks
            )
            #expect(summary.state == testCase.expectedState, Comment(rawValue: testCase.name))
            #expect(summary.reasons.contains(testCase.expectedReason), Comment(rawValue: testCase.name))
        }

        // use noCandidateLedger to keep warnings strict when building on Apple runner
        noCandidateLedger.clearCandidate()
        #expect(noCandidateLedger.candidateSelection == .unresolved)
    }

    @Test("unknown-safe rules never upgrade uncertain input")
    func unknownSafeCases() throws {
        let baseShot = Shot(id: shotID, sceneID: sceneID, title: "Close-up", status: .planned, requiredContinuityCheckIDs: [checkID])

        let goodTake = makeTake(
            id: "00000000-0000-0000-0000-000000000211",
            recordedAt: date(1),
            camera: "A-Cam"
        )

        var selected = try TakeLedger(entries: [goodTake], candidateSelection: .selected(goodTake.id))

        let cases: [Case] = [
            Case(
                name: "missing ledger",
                shot: baseShot,
                ledger: nil,
                checks: nil,
                expectedState: .unknown,
                expectedReason: .takeLedgerUnavailable
            ),
            Case(
                name: "candidate selection unknown",
                shot: baseShot,
                ledger: try TakeLedger(entries: [goodTake], candidateSelection: .unknown),
                checks: nil,
                expectedState: .unknown,
                expectedReason: .candidateSelectionUnknown
            ),
            Case(
                name: "missing candidate timing",
                shot: baseShot,
                ledger: try makeSelectedLedger(take: makeTake(
                    id: "00000000-0000-0000-0000-000000000212",
                    recordedAt: nil,
                    camera: "A-Cam"
                )),
                checks: nil,
                expectedState: .unknown,
                expectedReason: .candidateTimingMissing
            ),
            Case(
                name: "missing candidate camera",
                shot: baseShot,
                ledger: try makeSelectedLedger(take: makeTake(
                    id: "00000000-0000-0000-0000-000000000213",
                    recordedAt: date(2),
                    camera: "   "
                )),
                checks: nil,
                expectedState: .unknown,
                expectedReason: .candidateCameraMissing
            ),
            Case(
                name: "continuity requirements unavailable",
                shot: Shot(id: shotID, sceneID: sceneID, title: "Close-up", status: .planned, requiredContinuityCheckIDs: nil),
                ledger: selected,
                checks: nil,
                expectedState: .unknown,
                expectedReason: .continuityRequirementsUnavailable
            ),
            Case(
                name: "continuity check missing",
                shot: baseShot,
                ledger: selected,
                checks: [],
                expectedState: .unknown,
                expectedReason: .continuityCheckMissing
            ),
            Case(
                name: "continuity status unknown",
                shot: baseShot,
                ledger: selected,
                checks: [ContinuityCheck(id: checkID, shotID: shotID, label: "Cup", status: .unknown)],
                expectedState: .unknown,
                expectedReason: .continuityStatusUnknown
            )
        ]

        for testCase in cases {
            let summary = CoverageEngine.derive(
                shot: testCase.shot,
                ledger: testCase.ledger,
                continuityChecks: testCase.checks
            )
            #expect(summary.state == testCase.expectedState, Comment(rawValue: testCase.name))
            #expect(summary.reasons.contains(testCase.expectedReason), Comment(rawValue: testCase.name))
        }

        // keep selected mutable and exercised
        selected.markCandidateSelectionUnknown()
        #expect(selected.candidateSelection == .unknown)
    }

    @Test("summary includes take count and explicit candidate id")
    func summaryMetadata() throws {
        let shot = Shot(id: shotID, sceneID: sceneID, title: "Wide", status: .planned, requiredContinuityCheckIDs: [])
        let first = makeTake(
            id: "00000000-0000-0000-0000-000000000301",
            recordedAt: date(1),
            camera: "A-Cam"
        )
        let second = makeTake(
            id: "00000000-0000-0000-0000-000000000302",
            recordedAt: date(2),
            camera: "B-Cam"
        )
        var ledger = try TakeLedger(entries: [first, second], candidateSelection: .unresolved)
        try ledger.selectCandidate(second.id)

        let summary = CoverageEngine.derive(shot: shot, ledger: ledger, continuityChecks: nil)
        #expect(summary.takeCount == 2)
        #expect(summary.candidateTakeID == second.id)
        #expect(summary.state == .candidateSelected)
    }

    private struct Case {
        let name: String
        let shot: Shot
        let ledger: TakeLedger?
        let checks: [ContinuityCheck]?
        let expectedState: CoverageState
        let expectedReason: CoverageReason
    }

    private func makeTake(id: String, recordedAt: Date?, camera: String?) -> Take {
        Take(
            id: TakeID(rawValue: UUID(uuidString: id)!),
            shotID: shotID,
            recordedAt: recordedAt,
            durationSeconds: 2,
            cameraDescription: camera,
            rating: .keep,
            notes: ""
        )
    }

    private func makeSelectedLedger(take: Take) throws -> TakeLedger {
        var ledger = try TakeLedger(entries: [take], candidateSelection: .unresolved)
        try ledger.selectCandidate(take.id)
        return ledger
    }

    private func date(_ second: TimeInterval) -> Date {
        Date(timeIntervalSince1970: second)
    }
}
