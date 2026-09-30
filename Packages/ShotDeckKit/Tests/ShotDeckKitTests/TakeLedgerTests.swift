import Foundation
import Testing
@testable import ShotDeckKit

@Suite("Take ledger")
struct TakeLedgerTests {
    private let shotID = ShotID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)

    @Test("append preserves insertion order and provides current takes")
    func appendOrderAndCurrentTakes() throws {
        var ledger = try TakeLedger()

        let first = makeTake(
            id: "00000000-0000-0000-0000-000000000201",
            recordedAt: date(1),
            camera: "A-Cam 35mm"
        )
        let second = makeTake(
            id: "00000000-0000-0000-0000-000000000202",
            recordedAt: date(2),
            camera: "A-Cam 50mm"
        )
        let secondRevision = makeTake(
            id: "00000000-0000-0000-0000-000000000203",
            recordedAt: date(3),
            camera: "A-Cam 50mm",
            revisionOf: second.id
        )

        try ledger.append(first)
        try ledger.append(second)
        try ledger.append(secondRevision)

        #expect(ledger.entries.map(\.id) == [first.id, second.id, secondRevision.id])
        #expect(ledger.currentTakes.map(\.id) == [first.id, secondRevision.id])
    }

    @Test("ledger rejects duplicate, mixed-shot, and invalid revision writes")
    func ledgerValidationErrors() throws {
        var ledger = try TakeLedger()
        let first = makeTake(
            id: "00000000-0000-0000-0000-000000000210",
            recordedAt: date(1),
            camera: "A-Cam"
        )
        try ledger.append(first)

        let duplicate = makeTake(
            id: "00000000-0000-0000-0000-000000000210",
            recordedAt: date(2),
            camera: "B-Cam"
        )
        #expect(throws: TakeLedgerError.duplicateTakeID(duplicate.id)) {
            try ledger.append(duplicate)
        }

        let foreignShot = Take(
            id: TakeID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000211")!),
            shotID: ShotID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000999")!),
            recordedAt: date(2),
            durationSeconds: 2.5,
            cameraDescription: "B-Cam",
            rating: .keep,
            notes: "",
            revisionOf: nil
        )
        #expect(throws: TakeLedgerError.mixedShotIDs(expected: shotID, actual: foreignShot.shotID)) {
            try ledger.append(foreignShot)
        }

        let missingRevision = makeTake(
            id: "00000000-0000-0000-0000-000000000212",
            recordedAt: date(3),
            camera: "A-Cam",
            revisionOf: TakeID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000009999")!)
        )
        #expect(throws: TakeLedgerError.revisedTakeMissing(missingRevision.revisionOf!)) {
            try ledger.append(missingRevision)
        }

        let firstRevision = makeTake(
            id: "00000000-0000-0000-0000-000000000213",
            recordedAt: date(4),
            camera: "A-Cam",
            revisionOf: first.id
        )
        try ledger.append(firstRevision)

        let secondRevision = makeTake(
            id: "00000000-0000-0000-0000-000000000214",
            recordedAt: date(5),
            camera: "A-Cam",
            revisionOf: first.id
        )
        #expect(throws: TakeLedgerError.takeAlreadyRevised(first.id)) {
            try ledger.append(secondRevision)
        }
    }

    @Test("candidate selection is explicit and validated")
    func candidateSelectionContract() throws {
        let keep = makeTake(
            id: "00000000-0000-0000-0000-000000000220",
            recordedAt: date(1),
            camera: "A-Cam"
        )

        var ledger = try TakeLedger(entries: [keep], candidateSelection: .unresolved)

        try ledger.selectCandidate(keep.id)
        #expect(ledger.candidateSelection == .selected(keep.id))

        ledger.clearCandidate()
        #expect(ledger.candidateSelection == .unresolved)

        ledger.markCandidateSelectionUnknown()
        #expect(ledger.candidateSelection == .unknown)

        let missing = TakeID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000299")!)
        #expect(throws: TakeLedgerError.candidateTakeMissing(missing)) {
            try ledger.selectCandidate(missing)
        }
    }

    private func makeTake(
        id: String,
        recordedAt: Date?,
        camera: String?,
        revisionOf: TakeID? = nil
    ) -> Take {
        Take(
            id: TakeID(rawValue: UUID(uuidString: id)!),
            shotID: shotID,
            recordedAt: recordedAt,
            durationSeconds: 3.2,
            cameraDescription: camera,
            rating: .keep,
            notes: "",
            revisionOf: revisionOf
        )
    }

    private func date(_ second: TimeInterval) -> Date {
        Date(timeIntervalSince1970: second)
    }
}
