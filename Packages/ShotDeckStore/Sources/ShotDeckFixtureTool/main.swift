import Foundation
import GRDB
import ShotDeckKit
import ShotDeckStore

// ShotDeckFixtureTool — deterministic fixture generation and verification
// (issue #3). Local file operations only; zero network usage.
//
// Usage:
//   ShotDeckFixtureTool generate <path/to/fixture.sqlite>
//       Creates a v1-schema database seeded with the fixed fixture dataset.
//   ShotDeckFixtureTool verify <path/to/fixture.sqlite>
//       Opens the fixture, applies pending migrations (v1 -> current), and
//       asserts the migrated contents are lossless against the in-code
//       fixture definition. Exit 0 = lossless, exit 1 = mismatch.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FIXTURE TOOL: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("missing command (generate | verify)")
}

switch command {
case "generate":
    guard let path = arguments.dropFirst().first else {
        fail("generate requires an output path")
    }
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
    let queue = try DatabaseQueue(path: url.path)
    try Fixture.seedV1(queue)
    print("Generated v1 fixture at \(path)")
    exit(0)

case "verify":
    guard let path = arguments.dropFirst().first else {
        fail("verify requires a fixture path")
    }
    let url = URL(fileURLWithPath: path)
    // Copy before opening: ShotDeckStore applies pending migrations on open
    // and must never mutate the committed v1 fixture artifact.
    let scratchURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("shotdeck-verify-\(UUID().uuidString).sqlite")
    do {
        try FileManager.default.copyItem(at: url, to: scratchURL)
    } catch {
        fail("cannot copy fixture for verification: \(error)")
    }
    defer { try? FileManager.default.removeItem(at: scratchURL) }
    let store: ShotDeckStore
    do {
        // Opening applies pending migrations: v1 -> current schema.
        store = try ShotDeckStore(url: scratchURL)
    } catch {
        fail("cannot open fixture: \(error)")
    }
    let applied = (try? store.appliedMigrations()) ?? []
    print("Applied migrations after open: \(applied.joined(separator: ", "))")

    let snapshot: ShotDeckStore.Snapshot
    do {
        snapshot = try store.snapshot()
    } catch {
        fail("cannot snapshot migrated fixture: \(error)")
    }

    let expected = Fixture.projects()
    var problems: [String] = []
    if snapshot.projects != expected {
        problems.append("project set mismatch")
    }
    if snapshot.scenes != Fixture.scenes() {
        problems.append("scene set/order mismatch")
    }
    if snapshot.shots != Fixture.shots() {
        problems.append("shot set/order mismatch")
    }
    if snapshot.continuityChecks != Fixture.continuityChecks() {
        problems.append("continuity check mismatch")
    }
    if snapshot.sessionEvents != Fixture.sessionEvents() {
        problems.append("session event mismatch")
    }
    // Takes migrated losslessly: v1 had no duration/revision columns, so
    // expect the v1 facts preserved and v2 facts as explicit absence.
    let expectedLedger: TakeLedger
    do {
        expectedLedger = try TakeLedger(entries: Fixture.takes())
    } catch {
        fail("fixture ledger definition invalid: \(error)")
    }
    let migratedLedgers = snapshot.ledgers.map { $0.1 }
    let actualForA1 = migratedLedgers.first(where: { $0.shotID == Fixture.shotIDA1 })
    if actualForA1 != expectedLedger {
        problems.append("take ledger mismatch for shot A1 after migration")
    }
    if migratedLedgers.count != snapshot.shots.count {
        problems.append("ledger count mismatch")
    }

    if !problems.isEmpty {
        for problem in problems { print("MISMATCH: \(problem)") }
        fail("fixture verification failed")
    }
    print("Fixture verification: PASS (v1 -> current schema, lossless)")
    exit(0)

default:
    fail("unknown command: \(command)")
}
