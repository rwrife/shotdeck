import Foundation
import Testing
import GRDB
import ShotDeckKit
@testable import ShotDeckStore

@Suite("Local portability")
struct PortabilityTests {
    private func seeded() throws -> ShotDeckStore {
        let store = try ShotDeckStore()
        let p = ProjectID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let s = SceneID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let h = ShotID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        try store.savePlannerDocument(projects: [Project(id: p, title: "=Film, \"A\"", sceneIDs: [s])],
                                      scenes: [Scene(id: s, projectID: p, title: "Scene", shotIDs: [h])],
                                      shots: [Shot(id: h, sceneID: s, title: "Wide", actionNotes: "Line\nTwo")])
        let t = Take(id: TakeID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!),
                     shotID: h, recordedAt: Date(timeIntervalSince1970: 1700000000),
                     durationSeconds: 2.5, cameraDescription: nil, rating: .keep)
        try store.appendTake(t)
        let revision = Take(id: TakeID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!),
                            shotID: h, recordedAt: t.recordedAt, cameraDescription: "Camera", revisionOf: t.id)
        try store.appendTake(revision)
        try store.setCandidateSelection(.selected(revision.id), for: h)
        // Rollback clock: backup must preserve append order, not timestamp sort.
        try store.appendSessionEvent(SessionEvent(projectID: p, occurredAt: Date(timeIntervalSince1970: 200), kind: .sessionStarted))
        try store.appendSessionEvent(SessionEvent(projectID: p, occurredAt: Date(timeIntervalSince1970: 100), kind: .shotSelected, shotID: h))
        return store
    }

    @Test("preview does not mutate; round-trip retains corrections, candidates, replay and orphan history")
    func roundTrip() throws {
        let source = try seeded()
        let data = try source.backupData()
        let target = try seeded()
        try target.saveProject(Project(title: "Replace me"))
        let before = try target.backupData()
        let preview = try BackupArchive.decode(data)
        #expect(preview.projects.count == 1)
        #expect(preview.takeCount == 2)
        #expect(try target.backupData() == before)
        try target.restore(preview)
        #expect(try target.backupData() == data)
        let p = try source.allProjects()[0]
        #expect(try target.sessionEvents(in: p.id) == source.sessionEvents(in: p.id))
        try source.deleteProject(p.id)
        let orphanData = try source.backupData()
        let orphan = try BackupArchive.decode(orphanData)
        #expect(orphan.projects.isEmpty)
        #expect(orphan.takeCount == 2)
        try target.restore(orphan)
        #expect(try target.backupData() == orphanData)
    }

    @Test("future versions, malformed references, duplicate ids and invalid numbers leave data intact")
    func rejection() throws {
        let target = try seeded()
        let before = try target.backupData()
        var archive = try BackupArchive.decode(before)
        archive.version = 999
        #expect(throws: (any Error).self) { try target.restore(archive) }
        archive = try BackupArchive.decode(before)
        archive.projects.append(archive.projects[0])
        #expect(throws: (any Error).self) { try target.restore(archive) }
        archive = try BackupArchive.decode(before)
        archive.scenes[0].shotIDs.append(ShotID())
        // Dangling deleted planning IDs are allowed, but a wrong owner is not.
        archive.shots.append(Shot(sceneID: SceneID(), title: "Bad"))
        #expect(throws: (any Error).self) { try target.restore(archive) }
        archive = try BackupArchive.decode(before)
        let bad = Take(shotID: archive.shots[0].id, recordedAt: nil,
                       durationSeconds: -1, cameraDescription: nil)
        archive.ledgers[0].ledger = try TakeLedger(entries: [bad])
        #expect(throws: (any Error).self) { try target.restore(archive) }
        #expect(try target.backupData() == before)
        #expect(throws: (any Error).self) { _ = try BackupArchive.decode(Data("{}".utf8)) }
    }

    @Test("SQL failure after erase rolls back the entire replacement")
    func rollback() throws {
        let target = try seeded()
        let before = try target.backupData()
        try target.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse_restore BEFORE INSERT ON project BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        }
        #expect(throws: (any Error).self) { try target.restore(BackupArchive.decode(before)) }
        #expect(try target.backupData() == before)
    }

    @Test("JSON/CSV empty golden shapes and quoted ledger cells stay stable")
    func stableShapes() throws {
        let empty = try ShotDeckStore()
        #expect(String(decoding: try empty.backupData(), as: UTF8.self) == "{\"continuityChecks\":[],\"format\":\"shotdeck-backup\",\"ledgers\":[],\"projects\":[],\"scenes\":[],\"sessionEvents\":[],\"shots\":[],\"version\":1}")
        let reports = try empty.reports()
        #expect(reports.shotsCSV == "shot_id,scene_id,title,status,action_notes,reference_filename\r\n")
        #expect(reports.takesCSV == "shot_id,take_id,revision_of,recorded_at_utc,duration_seconds,camera,rating,notes,candidate\r\n")
        #expect(reports.coverageCSV == "shot_id,title,state,reasons,current_take_count,candidate_take_id\r\n")
        let report = try seeded().reports()
        #expect(report.shotsCSV.contains("\"Line\nTwo\""))
        #expect(report.takesCSV.contains("2.5"))
        #expect(report.takesCSV.contains("2023-11-14T22:13:20Z"))
        #expect(ReportBundle.csvCell("=SUM(A1)") == "'=SUM(A1)")
        #expect(ReportBundle.csvCell("a,\"b\"") == "\"a,\"\"b\"\"\"")
        #expect(report.printLines.contains(where: { $0.contains("Wide") }))
    }
}
