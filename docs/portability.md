# Portability, reports and privacy (issue #6)

From the Projects screen, open **Privacy & Files**. The user explicitly chooses **Save JSON backup**, a CSV, or **Save printable PDF**; Files picks the destination. No automatic upload or account is involved. To restore, choose a JSON file, review its project/scene/shot/take/check/event counts, then tap **Replace all data**. Cancel leaves the database untouched. Save a backup first: replacement is destructive and cannot be undone in ShotDeck. An invalid/future archive or an SQLite failure leaves the original database intact.

## Backup contract

- UTF-8 JSON, top-level `format: "shotdeck-backup"`, `version: 1`. Unknown versions are refused. Keys are sorted. Original UUIDs, plan order, take revisions, candidate state, checks, and append-ordered session events are preserved. History for deleted planner rows remains included. The archive is complete for *data in the local SQLite store*; reference filenames are strings, not bundled media.
- The app reads all tables from one SQLite snapshot. It validates IDs, relationships, revision chains, candidate IDs and positive finite durations before starting a single replacement transaction. A write failure rolls the entire replacement back. A preview parses and validates the file without modifying the store. At most 25 MB is accepted through the Files picker; larger files are refused.
- A user-initiated export is **unencrypted** and may contain titles, notes, camera descriptions, timestamps and session history. Choose a trusted location, apply device/file protection appropriate to your needs, and remove copies from shared storage after use. Files destinations (including cloud providers installed on the device) are under user control, not ShotDeck's. iPhone backup settings may separately include the local app database.

## Report contract

Three UTF-8 CSV files use comma separators, CRLF record separators, RFC 4180 quote doubling for quotes/commas/newlines, and fixed lowercase ASCII column names. `shots`: `shot_id,scene_id,title,status,action_notes,reference_filename`; `takes`: `shot_id,take_id,revision_of,recorded_at_utc,duration_seconds,camera,rating,notes,candidate`; `coverage`: `shot_id,title,state,reasons,current_take_count,candidate_take_id`. Timestamps are UTC ISO 8601 or blank when unknown; durations are seconds or blank; candidate is `yes`/`no` on each take row. `reasons` is a semicolon-joined list. Values starting with `=`, `+`, `-` or `@` after whitespace are prefixed with an apostrophe to prevent spreadsheet formula execution. CSVs are readable reports, **not** lossless restorable archives.

The PDF is a user-initiated printable coverage summary (project/shot/take counts and per-shot state/reasons), generated with UIKit in memory and handed to Files. It is not a restorable backup and does not embed the source database. No remote PDF service is used. No camera, microphone, photo library, contacts or location permissions are requested. The existing reference filename is a label and does not attach media.

## Recovery and verification

- If importing fails, keep the current database, inspect whether the file is a genuine version-1 JSON archive, and retry only after making a current backup. Never hand-edit IDs or revision pointers.
- If Files export fails, free device space or choose another provider; no saved copy is promised until Files reports success. CSV may be opened in any spreadsheet but must not be reimported as JSON.
- Linux package verification: `swift test --package-path Packages/ShotDeckKit`; `swift test --package-path Packages/ShotDeckStore`; `swift run --package-path Packages/ShotDeckStore ShotDeckFixtureTool verify Fixtures/shotdeck-fixture-v1.sqlite`; `bash scripts/check_zero_network.sh`; `bash scripts/check_native_only.sh`. Apple CI additionally uses exact Xcode 26.0.1 / SDK 26.0, builds an iPhone-only simulator app, checks built Info.plist and exercises the Privacy & Files entry in XCUITest. The Linux run does **not** prove UIKit PDF or Files picker behavior; the Apple runner must compile and test the native app.
