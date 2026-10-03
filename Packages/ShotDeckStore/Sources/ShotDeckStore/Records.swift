import Foundation
import GRDB
import ShotDeckKit

// MARK: - Fixed ISO-8601 date coding
//
// Dates are stored as fixed-format ISO-8601 strings so manifests are stable
// across platforms and locales, and fixtures remain human-inspectable.
// Only persistence internals use this encoder — the domain layer stays
// Foundation-standard.

nonisolated(unsafe) private let storeISO8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")!
    return formatter
}()

enum DateCoding {
    static func string(from date: Date?) -> String? {
        guard let date else { return nil }
        return storeISO8601.string(from: date)
    }

    static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        return storeISO8601.date(from: string)
    }
}

enum StoreCodingError: Error, Equatable {
    case malformedUUID(String)
    case malformedJSON(field: String)
}

func encodeJSONBLOB<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
        throw StoreCodingError.malformedJSON(field: String(reflecting: T.self))
    }
    return json
}

func decodeJSONBLOB<T: Decodable>(_ json: String, field: String) throws -> T {
    guard let data = json.data(using: .utf8) else {
        throw StoreCodingError.malformedJSON(field: field)
    }
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        throw StoreCodingError.malformedJSON(field: field)
    }
}

func uuidText(_ uuid: UUID) -> String { uuid.uuidString.uppercased() }

func parseUUID(_ text: String, field: String) throws -> UUID {
    guard let uuid = UUID(uuidString: text) else {
        throw StoreCodingError.malformedUUID("\(field): \(text)")
    }
    return uuid
}

// MARK: - Stored records

struct ProjectRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "project"

    var id: String
    var title: String
    var status: String
    var scene_ids: String
    var sort_key: String
    /// Explicit project list position (v3). Tie-breaks fall back to sort_key
    /// so pre-v3 data keeps its original visible order.
    var position: Int64

    static func from(domain project: Project, position: Int64 = 0) throws -> ProjectRecord {
        ProjectRecord(
            id: uuidText(project.id.rawValue),
            title: project.title,
            status: project.status.rawValue,
            scene_ids: try encodeJSONBLOB(project.sceneIDs.map { uuidText($0.rawValue) }),
            sort_key: ProjectRecord.defaultSortKey(
                title: project.title, id: uuidText(project.id.rawValue)),
            position: position
        )
    }

    static func defaultSortKey(title: String, id: String) -> String {
        "v1-sort:\(title):\(id)"
    }

    func toDomain() throws -> Project {
        guard let status = ProjectStatus(rawValue: status) else {
            throw StoreCodingError.malformedJSON(field: "project.status")
        }
        let sceneIDTexts: [String] = try decodeJSONBLOB(scene_ids, field: "project.scene_ids")
        var sceneIDs: [SceneID] = []
        sceneIDs.reserveCapacity(sceneIDTexts.count)
        for text in sceneIDTexts {
            sceneIDs.append(SceneID(rawValue: try parseUUID(text, field: "project.scene_ids")))
        }
        return Project(
            id: ProjectID(rawValue: try parseUUID(id, field: "project.id")),
            title: title,
            status: status,
            sceneIDs: sceneIDs
        )
    }
}

struct SceneRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "scene"

    var id: String
    var project_id: String
    var title: String
    var status: String
    var shot_ids: String
    var position: Int64

    static func from(domain scene: Scene, position: Int64) throws -> SceneRecord {
        SceneRecord(
            id: uuidText(scene.id.rawValue),
            project_id: uuidText(scene.projectID.rawValue),
            title: scene.title,
            status: scene.status.rawValue,
            shot_ids: try encodeJSONBLOB(scene.shotIDs.map { uuidText($0.rawValue) }),
            position: position
        )
    }

    func toDomain() throws -> Scene {
        guard let status = SceneStatus(rawValue: status) else {
            throw StoreCodingError.malformedJSON(field: "scene.status")
        }
        let shotIDTexts: [String] = try decodeJSONBLOB(shot_ids, field: "scene.shot_ids")
        var shotIDs: [ShotID] = []
        shotIDs.reserveCapacity(shotIDTexts.count)
        for text in shotIDTexts {
            shotIDs.append(ShotID(rawValue: try parseUUID(text, field: "scene.shot_ids")))
        }
        return Scene(
            id: SceneID(rawValue: try parseUUID(id, field: "scene.id")),
            projectID: ProjectID(rawValue: try parseUUID(project_id, field: "scene.project_id")),
            title: title,
            status: status,
            shotIDs: shotIDs
        )
    }
}

struct ShotRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "shot"

    var id: String
    var scene_id: String
    var title: String
    var status: String
    /// JSON text array of UUID strings, or the literal `null` meaning the
    /// continuity requirements are unavailable (domain `.unknown`-safe path).
    var required_ids: String?
    var position: Int64
    // Planner metadata (v3, issue #4).
    var framing_tags: String
    var lens_description: String?
    var orientation: String?
    var movement: String?
    var action_notes: String
    var reference_filename: String?
    var reference_caption: String?

    static func from(domain shot: Shot, position: Int64) throws -> ShotRecord {
        let requiredJSON: String?
        if let ids = shot.requiredContinuityCheckIDs {
            requiredJSON = try encodeJSONBLOB(ids.map { uuidText($0.rawValue) })
        } else {
            requiredJSON = "null"
        }
        return ShotRecord(
            id: uuidText(shot.id.rawValue),
            scene_id: uuidText(shot.sceneID.rawValue),
            title: shot.title,
            status: shot.status.rawValue,
            required_ids: requiredJSON,
            position: position,
            framing_tags: try encodeJSONBLOB(shot.framingTags),
            lens_description: shot.lensDescription,
            orientation: shot.orientation?.rawValue,
            movement: shot.movement?.rawValue,
            action_notes: shot.actionNotes,
            reference_filename: shot.referenceFilename,
            reference_caption: shot.referenceCaption
        )
    }

    func toDomain() throws -> Shot {
        guard let status = ShotStatus(rawValue: status) else {
            throw StoreCodingError.malformedJSON(field: "shot.status")
        }
        let requiredIDs: [ContinuityCheckID]?
        if let required_ids, required_ids != "null" {
            let texts: [String] = try decodeJSONBLOB(required_ids, field: "shot.required_ids")
            requiredIDs = try texts.map { text in
                ContinuityCheckID(rawValue: try parseUUID(text, field: "shot.required_ids"))
            }
        } else {
            requiredIDs = nil
        }
        let framingTags: [String] = try decodeJSONBLOB(framing_tags, field: "shot.framing_tags")
        return Shot(
            id: ShotID(rawValue: try parseUUID(id, field: "shot.id")),
            sceneID: SceneID(rawValue: try parseUUID(scene_id, field: "shot.scene_id")),
            title: title,
            status: status,
            requiredContinuityCheckIDs: requiredIDs,
            framingTags: framingTags,
            lensDescription: lens_description,
            // Unknown stored strings decode to explicit absence, never a
            // guessed value — same unknown-safe rule as the domain decoder.
            orientation: orientation.flatMap { ShotOrientation(rawValue: $0) },
            movement: movement.flatMap { ShotMovement(rawValue: $0) },
            actionNotes: action_notes,
            referenceFilename: reference_filename,
            referenceCaption: reference_caption
        )
    }
}

struct TakeRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "take"

    var id: String
    var shot_id: String
    var seq: Int64
    var recorded_at: String?
    var duration_seconds: Double?
    var camera_description: String?
    var rating: String
    var notes: String
    var revision_of: String?

    static func from(domain take: Take, seq: Int64) throws -> TakeRecord {
        TakeRecord(
            id: uuidText(take.id.rawValue),
            shot_id: uuidText(take.shotID.rawValue),
            seq: seq,
            recorded_at: DateCoding.string(from: take.recordedAt),
            duration_seconds: take.durationSeconds,
            camera_description: take.cameraDescription,
            rating: take.rating.rawValue,
            notes: take.notes,
            revision_of: take.revisionOf.map { uuidText($0.rawValue) }
        )
    }

    func toDomain() throws -> Take {
        guard let rating = TakeRating(rawValue: rating) else {
            throw StoreCodingError.malformedJSON(field: "take.rating")
        }
        return Take(
            id: TakeID(rawValue: try parseUUID(id, field: "take.id")),
            shotID: ShotID(rawValue: try parseUUID(shot_id, field: "take.shot_id")),
            recordedAt: DateCoding.date(from: recorded_at),
            durationSeconds: duration_seconds,
            cameraDescription: camera_description,
            rating: rating,
            notes: notes,
            revisionOf: try revision_of.map { TakeID(rawValue: try parseUUID($0, field: "take.revision_of")) }
        )
    }
}

struct ContinuityCheckRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "continuity_check"

    var id: String
    var shot_id: String
    var label: String
    var status: String
    var notes: String

    static func from(domain check: ContinuityCheck) throws -> ContinuityCheckRecord {
        ContinuityCheckRecord(
            id: uuidText(check.id.rawValue),
            shot_id: uuidText(check.shotID.rawValue),
            label: check.label,
            status: check.status.rawValue,
            notes: check.notes
        )
    }

    func toDomain() throws -> ContinuityCheck {
        guard let status = ContinuityCheckStatus(rawValue: status) else {
            throw StoreCodingError.malformedJSON(field: "continuity_check.status")
        }
        return ContinuityCheck(
            id: ContinuityCheckID(rawValue: try parseUUID(id, field: "continuity_check.id")),
            shotID: ShotID(rawValue: try parseUUID(shot_id, field: "continuity_check.shot_id")),
            label: label,
            status: status,
            notes: notes
        )
    }
}

struct SessionEventRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "session_event"

    var id: String
    var project_id: String
    var occurred_at: String
    var kind: String
    var shot_id: String?
    var take_id: String?

    static func from(domain event: SessionEvent) throws -> SessionEventRecord {
        SessionEventRecord(
            id: uuidText(event.id.rawValue),
            project_id: uuidText(event.projectID.rawValue),
            occurred_at: DateCoding.string(from: event.occurredAt) ?? "",
            kind: event.kind.rawValue,
            shot_id: event.shotID.map { uuidText($0.rawValue) },
            take_id: event.takeID.map { uuidText($0.rawValue) }
        )
    }

    func toDomain() throws -> SessionEvent {
        guard let kind = SessionEventKind(rawValue: kind) else {
            throw StoreCodingError.malformedJSON(field: "session_event.kind")
        }
        guard let occurredAt = DateCoding.date(from: occurred_at) else {
            throw StoreCodingError.malformedJSON(field: "session_event.occurred_at")
        }
        return SessionEvent(
            id: SessionEventID(rawValue: try parseUUID(id, field: "session_event.id")),
            projectID: ProjectID(rawValue: try parseUUID(project_id, field: "session_event.project_id")),
            occurredAt: occurredAt,
            kind: kind,
            shotID: try shot_id.map { ShotID(rawValue: try parseUUID($0, field: "session_event.shot_id")) },
            takeID: try take_id.map { TakeID(rawValue: try parseUUID($0, field: "session_event.take_id")) }
        )
    }
}

struct ShotCandidateRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "shot_candidate"

    var shot_id: String
    /// `unresolved`, `selected`, or `unknown` — mirrors
    /// `CandidateTakeSelection` without fabricating certainty.
    var selection_kind: String
    var take_id: String?
}

/// The v1 subset of `take` columns. Used to seed a v1-schema database
/// (fixture generation) before the duration/revision columns exist.
struct V1TakeRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "take"

    var id: String
    var shot_id: String
    var seq: Int64
    var recorded_at: String?
    var camera_description: String?
    var rating: String
    var notes: String
}

/// The v1 subset of `shot` columns (pre-planner-metadata schema).
struct V1ShotRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "shot"

    var id: String
    var scene_id: String
    var title: String
    var status: String
    var required_ids: String?
    var position: Int64
}

/// The v1 subset of `project` columns (pre-project-position schema).
struct V1ProjectRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "project"

    var id: String
    var title: String
    var status: String
    var scene_ids: String
    var sort_key: String
}
