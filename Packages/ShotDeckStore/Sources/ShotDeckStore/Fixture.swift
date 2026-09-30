import Foundation
import GRDB
import ShotDeckKit

/// Deterministic fixture dataset committed with the repo (issue #3).
///
/// Every UUID and timestamp is fixed so fixture generation and verification
/// are byte-reproducible. The fixture exercises v1-representable data only
/// (no durations, no revisions, no candidate selections) so a v1 database
/// built from it can be migrated to the current schema losslessly.
public enum Fixture {
    public static let fixtureFileName = "shotdeck-fixture-v1.sqlite"

    // Fixed clock: 2026-03-01T09:00:00Z and friends.
    private static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")!
        guard let parsed = formatter.date(from: iso) else {
            preconditionFailure("fixture ISO-8601 constant must parse: \(iso)")
        }
        return parsed
    }

    // Fixed identifiers (UUID v4 text constants).
    public static let projectID = ProjectID(rawValue: UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!)
    public static let sceneIDA = SceneID(rawValue: UUID(uuidString: "A2000000-0000-4000-8000-000000000001")!)
    public static let sceneIDB = SceneID(rawValue: UUID(uuidString: "A2000000-0000-4000-8000-000000000002")!)
    public static let shotIDA1 = ShotID(rawValue: UUID(uuidString: "A3000000-0000-4000-8000-000000000001")!)
    public static let shotIDA2 = ShotID(rawValue: UUID(uuidString: "A3000000-0000-4000-8000-000000000002")!)
    public static let shotIDB1 = ShotID(rawValue: UUID(uuidString: "A3000000-0000-4000-8000-000000000003")!)
    public static let takeIDA1R1 = TakeID(rawValue: UUID(uuidString: "A4000000-0000-4000-8000-000000000001")!)
    public static let takeIDA1R2 = TakeID(rawValue: UUID(uuidString: "A4000000-0000-4000-8000-000000000002")!)
    public static let checkIDWardrobe = ContinuityCheckID(rawValue: UUID(uuidString: "A5000000-0000-4000-8000-000000000001")!)
    public static let checkIDProp = ContinuityCheckID(rawValue: UUID(uuidString: "A5000000-0000-4000-8000-000000000002")!)
    public static let eventIDStart = SessionEventID(rawValue: UUID(uuidString: "A6000000-0000-4000-8000-000000000001")!)
    public static let eventIDTake = SessionEventID(rawValue: UUID(uuidString: "A6000000-0000-4000-8000-000000000002")!)

    /// The complete fixture in canonical insertion order.
    public static func projects() -> [Project] {
        [
            Project(
                id: projectID,
                title: "Downtown Interview",
                status: .active,
                sceneIDs: [sceneIDA, sceneIDB]
            ),
        ]
    }

    public static func scenes() -> [Scene] {
        [
            Scene(
                id: sceneIDA,
                projectID: projectID,
                title: "Scene A — Lobby",
                status: .active,
                shotIDs: [shotIDA1, shotIDA2]
            ),
            Scene(
                id: sceneIDB,
                projectID: projectID,
                title: "Scene B — Rooftop",
                status: .planned,
                shotIDs: [shotIDB1]
            ),
        ]
    }

    public static func shots() -> [Shot] {
        [
            // A1: two required continuity checks with real check rows.
            Shot(
                id: shotIDA1,
                sceneID: sceneIDA,
                title: "A1 — Wide establishing",
                status: .active,
                requiredContinuityCheckIDs: [checkIDWardrobe, checkIDProp]
            ),
            // A2: explicitly zero required checks (empty array, not unknown).
            Shot(
                id: shotIDA2,
                sceneID: sceneIDA,
                title: "A2 — Tight two-shot",
                status: .planned,
                requiredContinuityCheckIDs: []
            ),
            // B1: continuity requirements unavailable (nil) — unknown-safe.
            Shot(
                id: shotIDB1,
                sceneID: sceneIDB,
                title: "B1 — Golden hour pull",
                status: .unknown,
                requiredContinuityCheckIDs: nil
            ),
        ]
    }

    /// v1-representable takes only (no durations, no revisions).
    public static func takes() -> [Take] {
        [
            Take(
                id: takeIDA1R1,
                shotID: shotIDA1,
                recordedAt: date("2026-03-01T09:05:00Z"),
                durationSeconds: nil,
                cameraDescription: "A-cam, 35mm",
                rating: .unreviewed,
                notes: "First pass, talent early on lines"
            ),
            Take(
                id: takeIDA1R2,
                shotID: shotIDA1,
                recordedAt: date("2026-03-01T09:12:30Z"),
                durationSeconds: nil,
                cameraDescription: "A-cam, 35mm",
                rating: .keep,
                notes: "Clean take"
            ),
        ]
    }

    public static func continuityChecks() -> [ContinuityCheck] {
        [
            ContinuityCheck(
                id: checkIDWardrobe,
                shotID: shotIDA1,
                label: "Wardrobe: jacket buttoned",
                status: .matched,
                notes: ""
            ),
            ContinuityCheck(
                id: checkIDProp,
                shotID: shotIDA1,
                label: "Prop: coffee mug half-full",
                status: .pending,
                notes: "Top up before next setup"
            ),
        ]
    }

    public static func sessionEvents() -> [SessionEvent] {
        [
            SessionEvent(
                id: eventIDStart,
                projectID: projectID,
                occurredAt: date("2026-03-01T09:00:00Z"),
                kind: .sessionStarted,
                shotID: nil,
                takeID: nil
            ),
            SessionEvent(
                id: eventIDTake,
                projectID: projectID,
                occurredAt: date("2026-03-01T09:12:30Z"),
                kind: .takeAppended,
                shotID: shotIDA1,
                takeID: takeIDA1R2
            ),
        ]
    }

    /// Write the complete fixture dataset with the v1-only schema.
    /// Used by the committed-fixture generator and by migration tests.
    public static func seedV1(_ writer: any DatabaseWriter) throws {
        try Schema.v1OnlyMigrator().migrate(writer)
        try writer.write { db in try seedV1Data(db) }
    }

    static func seedV1Data(_ db: Database) throws {
        for (offset, project) in projects().enumerated() {
            var record = try ProjectRecord.from(domain: project)
            // Deterministic visible ordering independent of title text.
            record.sort_key = "v1fixture-\(String(format: "%04d", offset)):\(record.id)"
            try record.insert(db)
        }
        for (offset, scene) in scenes().enumerated() {
            var sceneRecord = try SceneRecord.from(domain: scene, position: Int64(offset))
            try sceneRecord.insert(db)
        }
        for (offset, shot) in shots().enumerated() {
            var shotRecord = try ShotRecord.from(domain: shot, position: Int64(offset))
            try shotRecord.insert(db)
        }
        for (offset, take) in takes().enumerated() {
            // v1 has no duration/revision columns — write the v1 subset.
            var takeRow = V1TakeRow(
                id: uuidText(take.id.rawValue),
                shot_id: uuidText(take.shotID.rawValue),
                seq: Int64(offset + 1),
                recorded_at: DateCoding.string(from: take.recordedAt),
                camera_description: take.cameraDescription,
                rating: take.rating.rawValue,
                notes: take.notes
            )
            try takeRow.insert(db)
        }
        for check in continuityChecks() {
            var checkRecord = try ContinuityCheckRecord.from(domain: check)
            try checkRecord.insert(db)
        }
        for event in sessionEvents() {
            var eventRecord = try SessionEventRecord.from(domain: event)
            try eventRecord.insert(db)
        }
    }

    /// The dataset this store build can hold — includes v2-only facts
    /// (durations, revisions, candidate selection) used by round-trip tests.
    public static func currentExtensionTakes() -> [Take] {
        [
            Take(
                id: takeIDA1R1,
                shotID: shotIDA1,
                recordedAt: date("2026-03-01T09:05:00Z"),
                durationSeconds: 41.5,
                cameraDescription: "A-cam, 35mm",
                rating: .reject,
                notes: "Boom shadow in frame",
                revisionOf: nil
            ),
            Take(
                id: takeIDA1R2,
                shotID: shotIDA1,
                recordedAt: date("2026-03-01T09:12:30Z"),
                durationSeconds: 43.0,
                cameraDescription: "A-cam, 35mm",
                rating: .keep,
                notes: "Clean take",
                revisionOf: takeIDA1R1
            ),
        ]
    }
}
