import Foundation
import GRDB

/// Explicit schema versioning for ShotDeck persistence.
///
/// Every schema change is a named, ordered migration registered here. The
/// GRDB `DatabaseMigrator` records applied migrations in its internal
/// `grdb_migrations` table; `Schema.currentVersion` is the highest version
/// this build knows about.
public enum Schema {
    public static let migrationV1 = "v1-initial"
    public static let migrationV2 = "v2-take-revisions-and-candidates"
    public static let migrationV3 = "v3-planner-metadata"

    /// Highest schema version defined by this build of the app.
    public static let currentVersion = 3

    /// All migrations for a fresh or existing store.
    static func fullMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // Surface migration bugs loudly during development/testing.
        migrator.eraseDatabaseOnSchemaChange = false
        #endif
        registerV1(&migrator)
        registerV2(&migrator)
        registerV3(&migrator)
        return migrator
    }

    /// Only the v1 schema — used to build the committed v1 fixture database
    /// so the migration path is exercised for real in tests and CI.
    static func v1OnlyMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerV1(&migrator)
        return migrator
    }

    private static func registerV1(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(migrationV1) { db in
            try db.create(table: "project") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("status", .text).notNull()
                t.column("scene_ids", .text).notNull()
                t.column("sort_key", .text).notNull()
            }
            try db.create(table: "scene") { t in
                t.column("id", .text).primaryKey()
                t.column("project_id", .text).notNull()
                t.column("title", .text).notNull()
                t.column("status", .text).notNull()
                t.column("shot_ids", .text).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(index: "scene_project_position", on: "scene", columns: ["project_id", "position"])
            try db.create(table: "shot") { t in
                t.column("id", .text).primaryKey()
                t.column("scene_id", .text).notNull()
                t.column("title", .text).notNull()
                t.column("status", .text).notNull()
                // JSON text array of UUID strings, or the literal text "null"
                // meaning continuity requirements are unavailable.
                t.column("required_ids", .text)
                t.column("position", .integer).notNull()
            }
            try db.create(index: "shot_scene_position", on: "shot", columns: ["scene_id", "position"])
            try db.create(table: "take") { t in
                t.column("id", .text).primaryKey()
                t.column("shot_id", .text).notNull()
                t.column("seq", .integer).notNull()
                t.column("recorded_at", .text)
                t.column("camera_description", .text)
                t.column("rating", .text).notNull()
                t.column("notes", .text).notNull()
            }
            try db.create(index: "take_shot_seq", on: "take", columns: ["shot_id", "seq"])
            try db.create(table: "continuity_check") { t in
                t.column("id", .text).primaryKey()
                t.column("shot_id", .text).notNull()
                t.column("label", .text).notNull()
                t.column("status", .text).notNull()
                t.column("notes", .text).notNull()
            }
            try db.create(index: "continuity_check_shot", on: "continuity_check", columns: ["shot_id"])
            try db.create(table: "session_event") { t in
                t.column("id", .text).primaryKey()
                t.column("project_id", .text).notNull()
                t.column("occurred_at", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("shot_id", .text)
                t.column("take_id", .text)
            }
            try db.create(index: "session_event_project_time", on: "session_event", columns: ["project_id", "occurred_at"])
        }
    }

    private static func registerV2(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(migrationV2) { db in
            // Append-only revision chains (domain TakeLedger) become storable.
            try db.alter(table: "take") { t in
                t.add(column: "duration_seconds", .double)
                t.add(column: "revision_of", .text)
            }
            // Explicit, nullable candidate selection per shot. Absent row or
            // `unresolved` kind never fabricates a selection.
            try db.create(table: "shot_candidate") { t in
                t.column("shot_id", .text).primaryKey()
                t.column("selection_kind", .text).notNull()
                t.column("take_id", .text)
            }
        }
    }

    private static func registerV3(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(migrationV3) { db in
            // Planner metadata for shots (issue #4). Defaults encode the
            // honest pre-issue-#4 state: no tags, no notes, no reference —
            // never a fabricated value.
            try db.alter(table: "shot") { t in
                t.add(column: "framing_tags", .text).notNull().defaults(to: "[]")
                t.add(column: "lens_description", .text)
                t.add(column: "orientation", .text)
                t.add(column: "movement", .text)
                t.add(column: "action_notes", .text).notNull().defaults(to: "")
                t.add(column: "reference_filename", .text)
                t.add(column: "reference_caption", .text)
            }
            // Project list becomes explicitly reorderable like scenes/shots.
            try db.alter(table: "project") { t in
                t.add(column: "position", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "project_position", on: "project", columns: ["position"])
        }
    }
}
