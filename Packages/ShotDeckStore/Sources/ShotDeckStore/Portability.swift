import Foundation
import GRDB
import ShotDeckKit

public enum BackupError: Error, Equatable, Sendable {
    case unsupportedFormat
    case invalidData(String)
}

/// A versioned, unencrypted copy of *all* user rows including orphaned take
/// history after a planner deletion. Treat the file as sensitive personal data.
public struct BackupArchive: Codable, Sendable {
    public var format = "shotdeck-backup"
    public var version = 1
    public var projects: [Project] = []
    public var scenes: [Scene] = []
    public var shots: [Shot] = []
    public var ledgers: [BackupLedger] = []
    public var continuityChecks: [ContinuityCheck] = []
    public var sessionEvents: [SessionEvent] = []

    public var takeCount: Int { ledgers.reduce(0) { $0 + $1.ledger.entries.count } }

    public static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    public func data() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Reject ambiguous, non-finite, or invalid input *before* any deletion.
    /// Missing referenced planner rows are permitted: a deleted planner does
    /// not erase audit history or the ordered ID lists of retained ancestors.
    public func validate() throws {
        guard format == "shotdeck-backup", version == 1 else { throw BackupError.unsupportedFormat }
        func unique<ID: Hashable>(_ values: [ID], _ label: String) throws {
            guard Set(values).count == values.count else { throw BackupError.invalidData("duplicate \(label)") }
        }
        try unique(projects.map(\.id), "project")
        try unique(scenes.map(\.id), "scene")
        try unique(shots.map(\.id), "shot")
        try unique(ledgers.map(\.shotID), "ledger")
        try unique(continuityChecks.map(\.id), "check")
        try unique(sessionEvents.map(\.id), "event")
        let sceneMap = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })
        let shotMap = Dictionary(uniqueKeysWithValues: shots.map { ($0.id, $0) })
        for project in projects {
            try unique(project.sceneIDs, "project scene reference")
            for id in project.sceneIDs {
                if let scene = sceneMap[id], scene.projectID != project.id {
                    throw BackupError.invalidData("scene belongs to another project")
                }
            }
        }
        for scene in scenes {
            guard projects.contains(where: { $0.id == scene.projectID }) else {
                throw BackupError.invalidData("orphan scene")
            }
            try unique(scene.shotIDs, "scene shot reference")
            for id in scene.shotIDs {
                if let shot = shotMap[id], shot.sceneID != scene.id {
                    throw BackupError.invalidData("shot belongs to another scene")
                }
            }
        }
        for shot in shots {
            guard sceneMap[shot.sceneID] != nil else { throw BackupError.invalidData("orphan shot") }
            if let ids = shot.requiredContinuityCheckIDs { try unique(ids, "required check") }
        }
        var allTakeIDs: [TakeID] = []
        for entry in ledgers {
            // TakeLedger.decode checks revision chains and candidate validity.
            for take in entry.ledger.entries {
                guard take.shotID == entry.shotID else { throw BackupError.invalidData("mixed shot ledger") }
                if let duration = take.durationSeconds, !duration.isFinite || duration <= 0 {
                    throw BackupError.invalidData("invalid take duration")
                }
                allTakeIDs.append(take.id)
            }
            _ = try TakeLedger(entries: entry.ledger.entries,
                               candidateSelection: entry.ledger.candidateSelection)
        }
        try unique(allTakeIDs, "take")
        for check in continuityChecks {
            if let shot = shotMap[check.shotID],
               let ids = shot.requiredContinuityCheckIDs, !ids.contains(check.id) {
                throw BackupError.invalidData("check not required by its shot")
            }
        }
    }
}

public struct BackupLedger: Codable, Sendable {
    public var shotID: ShotID
    public var ledger: TakeLedger
    public init(shotID: ShotID, ledger: TakeLedger) {
        self.shotID = shotID
        self.ledger = ledger
    }
}

public struct ReportBundle: Sendable {
    public let shotsCSV: String
    public let takesCSV: String
    public let coverageCSV: String
    /// Semantic lines shared by the printable iPhone PDF renderer and tests.
    public let printLines: [String]

    /// RFC 4180 escaping plus spreadsheet-formula neutralization for
    /// untrusted, user-entered cells. Commas/newlines/quotes are preserved.
    public static func csvCell(_ text: String) -> String {
        let first = text.drop(while: { $0 == " " || $0 == "\t" }).first
        let safe = ["=", "+", "-", "@"].contains(first.map(String.init) ?? "") ? "'" + text : text
        if safe.contains(",") || safe.contains("\"") || safe.contains("\r") || safe.contains("\n") {
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return safe
    }

    private static func csv(_ header: [String], _ rows: [[String]]) -> String {
        ( [header] + rows ).map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    public init(_ archive: BackupArchive) {
        let ledgers = Dictionary(uniqueKeysWithValues: archive.ledgers.map { ($0.shotID, $0.ledger) })
        shotsCSV = Self.csv(["shot_id", "scene_id", "title", "status", "action_notes", "reference_filename"],
            archive.shots.map { [$0.id.rawValue.uuidString, $0.sceneID.rawValue.uuidString,
                                  $0.title, $0.status.rawValue, $0.actionNotes, $0.referenceFilename ?? ""] })
        var takeRows: [[String]] = []
        for entry in archive.ledgers {
            for take in entry.ledger.entries {
                let selected: String
                if entry.ledger.candidateSelection == .selected(take.id) { selected = "yes" }
                else { selected = "no" }
                takeRows.append([entry.shotID.rawValue.uuidString, take.id.rawValue.uuidString,
                    take.revisionOf?.rawValue.uuidString ?? "", DateCoding.string(from: take.recordedAt) ?? "",
                    take.durationSeconds.map { String($0) } ?? "", take.cameraDescription ?? "",
                    take.rating.rawValue, take.notes, selected])
            }
        }
        takesCSV = Self.csv(["shot_id", "take_id", "revision_of", "recorded_at_utc", "duration_seconds", "camera", "rating", "notes", "candidate"], takeRows)
        let checks = Dictionary(grouping: archive.continuityChecks, by: \.shotID)
        coverageCSV = Self.csv(["shot_id", "title", "state", "reasons", "current_take_count", "candidate_take_id"],
            archive.shots.map { shot in
                let summary = CoverageEngine.derive(shot: shot,
                    ledger: ledgers[shot.id], continuityChecks: checks[shot.id] ?? [])
                let candidate: String
                if case let .selected(id) = ledgers[shot.id]?.candidateSelection { candidate = id.rawValue.uuidString }
                else { candidate = "" }
                let reasonsStr = summary.reasons.map(\.rawValue).joined(separator: ";")
                return [shot.id.rawValue.uuidString, shot.title, summary.state.rawValue,
                        reasonsStr, String(ledgers[shot.id]?.currentTakes.count ?? 0), candidate]
            })
        printLines = ["ShotDeck — Shoot report", "Projects: \(archive.projects.count) · Shots: \(archive.shots.count) · Takes: \(archive.takeCount)"]
            + archive.shots.map { shot in
                let summary = CoverageEngine.derive(shot: shot,
                    ledger: ledgers[shot.id], continuityChecks: checks[shot.id] ?? [])
                let reasonsStr = summary.reasons.map(\.rawValue).joined(separator: ";")
                return "\(shot.title) — \(summary.state.rawValue) (\(reasonsStr))"
            }
    }
}

extension ShotDeckStore {
    /// All tables are read under one SQLite snapshot, including history not
    /// reachable from current planner rows. Order is stable across reopens.
    public func backup() throws -> BackupArchive {
        try read { db in
            var archive = BackupArchive()
            archive.projects = try ProjectRecord.order(Column("position"), Column("sort_key"), Column("id"))
                .fetchAll(db).map { try $0.toDomain() }
            archive.scenes = try SceneRecord.order(Column("project_id"), Column("position"), Column("id"))
                .fetchAll(db).map { try $0.toDomain() }
            archive.shots = try ShotRecord.order(Column("scene_id"), Column("position"), Column("id"))
                .fetchAll(db).map { try $0.toDomain() }
            let takeRows = try TakeRecord.order(Column("shot_id"), Column("seq"), Column("id")).fetchAll(db)
            let candidateRows = try ShotCandidateRecord.order(Column("shot_id")).fetchAll(db)
            let keys = Set(takeRows.map(\.shot_id) + candidateRows.map(\.shot_id)
                + archive.shots.map { uuidText($0.id.rawValue) })
            for key in keys.sorted() {
                let id = ShotID(rawValue: try parseUUID(key, field: "ledger.shot_id"))
                let entries = try takeRows.filter { $0.shot_id == key }.map { try $0.toDomain() }
                let row = candidateRows.first { $0.shot_id == key }
                let selection: CandidateTakeSelection
                switch row?.selection_kind {
                case "selected":
                    guard let raw = row?.take_id, let uuid = UUID(uuidString: raw) else {
                        throw BackupError.invalidData("invalid candidate id")
                    }
                    selection = .selected(TakeID(rawValue: uuid))
                case "unknown": selection = .unknown
                case nil, "unresolved": selection = .unresolved
                default: throw BackupError.invalidData("invalid candidate selection")
                }
                archive.ledgers.append(BackupLedger(shotID: id,
                    ledger: try TakeLedger(entries: entries, candidateSelection: selection)))
            }
            archive.continuityChecks = try ContinuityCheckRecord.order(Column("id"))
                .fetchAll(db).map { try $0.toDomain() }
            // rowid, not date: a device clock can roll backwards during a session.
            archive.sessionEvents = try SessionEventRecord.order(sql: "rowid")
                .fetchAll(db).map { try $0.toDomain() }
            try archive.validate()
            return archive
        }
    }

    public func backupData() throws -> Data { try backup().data() }
    public func reports() throws -> ReportBundle { ReportBundle(try backup()) }

    /// Explicit destructive replacement: caller must preview the archive and
    /// get confirmation first. One transaction keeps the old DB on any error.
    public func restore(_ archive: BackupArchive) throws {
        try archive.validate()
        try write { db in
            for table in ["session_event", "shot_candidate", "continuity_check", "take", "shot", "scene", "project"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            for (position, project) in archive.projects.enumerated() {
                var row = try ProjectRecord.from(domain: project, position: Int64(position))
                try row.insert(db)
            }
            for (position, scene) in archive.scenes.enumerated() {
                var row = try SceneRecord.from(domain: scene,
                    position: Int64(archive.projects.first(where: { $0.id == scene.projectID })?
                        .sceneIDs.firstIndex(of: scene.id) ?? position))
                try row.insert(db)
            }
            for (position, shot) in archive.shots.enumerated() {
                var row = try ShotRecord.from(domain: shot,
                    position: Int64(archive.scenes.first(where: { $0.id == shot.sceneID })?
                        .shotIDs.firstIndex(of: shot.id) ?? position))
                try row.insert(db)
            }
            for entry in archive.ledgers {
                for (offset, take) in entry.ledger.entries.enumerated() {
                    var row = try TakeRecord.from(domain: take, seq: Int64(offset + 1))
                    try row.insert(db)
                }
                let kind: String
                let takeID: String?
                switch entry.ledger.candidateSelection {
                case .selected(let id): kind = "selected"; takeID = uuidText(id.rawValue)
                case .unresolved: kind = "unresolved"; takeID = nil
                case .unknown: kind = "unknown"; takeID = nil
                }
                var candidate = ShotCandidateRecord(shot_id: uuidText(entry.shotID.rawValue),
                                                    selection_kind: kind, take_id: takeID)
                try candidate.insert(db)
            }
            for check in archive.continuityChecks {
                var row = try ContinuityCheckRecord.from(domain: check)
                try row.insert(db)
            }
            for event in archive.sessionEvents {
                var row = try SessionEventRecord.from(domain: event)
                try row.insert(db)
            }
        }
    }
}
