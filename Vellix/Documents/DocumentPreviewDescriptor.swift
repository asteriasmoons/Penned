import CryptoKit
import Foundation
import GRDB
import os
#if canImport(UIKit)
import UIKit
#endif

// Structured, device-local diagnostics for the first-launch descriptor migration
// and preview regeneration. Each device logs independently (no CloudKit state is
// introduced for logging); the device tag distinguishes iPhone and iPad console
// output. Logging never includes document contents or identifiers.
nonisolated enum PennedDiagnostics {
    static let deviceTag: String = {
        #if canImport(UIKit)
        let idiom = UIDevice.current.userInterfaceIdiom
        let kind = idiom == .pad ? "iPad" : (idiom == .phone ? "iPhone" : "iOS")
        return "\(kind) \(UIDevice.current.systemVersion)"
        #else
        return "mac"
        #endif
    }()
    private static let subsystem = Bundle.main.bundleIdentifier ?? "im.lystaria.Vellix"
    static let migration = Logger(subsystem: subsystem, category: "PennedMigration")
    static let previews = Logger(subsystem: subsystem, category: "PennedPreviews")
    private static let startup = Logger(subsystem: subsystem, category: "PennedStartup")

    @discardableResult
    static func markStartup(_ phase: String, since start: TimeInterval? = nil) -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsedMS = start.map { Int((now - $0) * 1_000) } ?? 0
        startup.notice("[Penned Startup] phase=\(phase, privacy: .public) uptimeMS=\(Int64(now * 1_000), privacy: .public) elapsedMS=\(elapsedMS, privacy: .public)")
        return now
    }

    // TEMP: one-shot startup marker (fires once per phase) for timing the first
    // evaluation of a SwiftUI body. Called from the main thread only.
    nonisolated(unsafe) private static var startupOnceFired = Set<String>()
    static func markStartupOnce(_ phase: String) {
        guard startupOnceFired.insert(phase).inserted else { return }
        _ = markStartup(phase)
    }
}

// Preview-regeneration diagnostics, kept separate from descriptor migration because
// previews regenerate lazily on demand (as the library is browsed) rather than
// through a bulk queue. Completion therefore reflects only previews rendered so far,
// never all possible previews — and this is never reported complete merely because
// the descriptor backfill finished. Counters are process-wide and thread-safe.
nonisolated enum PennedPreviewDiagnostics {
    private static let lock = NSLock()
    private static var regenerated = 0
    private static var failures = 0
    private static var lastLoggedAt = 0
    private static var announced = false

    // One-time, at launch: the preview cache version and the lazy regeneration model.
    static func announce(version: String) {
        lock.lock(); let first = !announced; announced = true; lock.unlock()
        guard first else { return }
        let device = PennedDiagnostics.deviceTag
        let log = PennedDiagnostics.previews
        log.notice("[Penned Previews] (\(device, privacy: .public)) Preview cache version: \(version, privacy: .public)")
        log.notice("[Penned Previews] (\(device, privacy: .public)) Cached previews are keyed by this version; a version change invalidates them and each regenerates the next time its document is rendered.")
        log.notice("[Penned Previews] (\(device, privacy: .public)) Regeneration is on demand (lazy) as the library is browsed — there is no bulk preview queue, so the count awaiting regeneration is not determinable and completion reflects only previews rendered so far, never all possible previews.")
    }

    static func recordRegenerated() {
        lock.lock()
        regenerated += 1
        let count = regenerated, fails = failures
        let shouldLog = regenerated - lastLoggedAt >= 25
        if shouldLog { lastLoggedAt = regenerated }
        lock.unlock()
        if shouldLog {
            PennedDiagnostics.previews.notice("[Penned Previews] (\(PennedDiagnostics.deviceTag, privacy: .public)) Regenerated on demand so far: \(count, privacy: .public) previews (failures \(fails, privacy: .public)); lazy regeneration ongoing, not a completed set.")
        }
    }

    static func recordFailure(_ message: String) {
        lock.lock(); failures += 1; let fails = failures; lock.unlock()
        PennedDiagnostics.previews.error("[Penned Previews] (\(PennedDiagnostics.deviceTag, privacy: .public)) Regeneration failure #\(fails, privacy: .public): \(message, privacy: .public)")
    }
}

// A persistent, local-only fingerprint of the preview-relevant facts that can
// otherwise only be learned by parsing a document's full tipTapJSON. The library
// gallery uses it to build preview cache keys and resolve page/collection
// relationships without loading or scanning document bodies.
//
// This is a derived index of document JSON, never an independently editable copy
// of content, and it is deliberately NOT part of CloudKit library sync: the sync
// record validator requires an exact column-set match against the live `documents`
// schema, so adding synced columns there would break cross-version sync. The
// descriptor therefore lives in its own table (absent from LibrarySyncSchema.tables)
// and is recomputed locally from the document body on every change, including
// synchronization imports.
nonisolated struct DocumentPreviewDescriptor: Equatable, Sendable {
    // Preview features that are detected by scanning the full document body. Each
    // flag mirrors exactly one presentation check in DocumentPreviewContent.cacheKey
    // so the key can be reproduced from the descriptor instead of the raw JSON.
    struct Features: OptionSet, Sendable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }

        static let inlineProperties   = Features(rawValue: 1 << 0)
        static let callouts           = Features(rawValue: 1 << 1)
        static let listGrids          = Features(rawValue: 1 << 2)
        static let codeBlock          = Features(rawValue: 1 << 3)
        static let gridCards          = Features(rawValue: 1 << 4)
        static let headingLabel       = Features(rawValue: 1 << 5)
        static let texturedLabel      = Features(rawValue: 1 << 6)
        static let decorativeLabel    = Features(rawValue: 1 << 7)
        static let tabs               = Features(rawValue: 1 << 8)
        static let minimalFields      = Features(rawValue: 1 << 9)
        static let fourDotDivider     = Features(rawValue: 1 << 10)
        static let templateComponent  = Features(rawValue: 1 << 11)
        static let attachment         = Features(rawValue: 1 << 12)
        static let inlineTags         = Features(rawValue: 1 << 13)
        static let toggles            = Features(rawValue: 1 << 14)
        static let clipSources        = Features(rawValue: 1 << 15)
        static let table              = Features(rawValue: 1 << 16)
        static let blockquote         = Features(rawValue: 1 << 17)
        static let informationCard    = Features(rawValue: 1 << 18)
        static let richLink           = Features(rawValue: 1 << 19)
    }

    var documentID: String
    // Stable hash of the canonical document body. Stands in for the raw tipTapJSON
    // wherever the preview cache key previously hashed the full body string.
    var contentHash: String
    var features: Features
    // Document IDs referenced by `pageReference` nodes embedded in this body.
    var pageReferenceIDs: Set<String>
    // Collection IDs referenced by `collection` nodes embedded in this body.
    var collectionIDs: Set<String>

    func contains(_ feature: Features) -> Bool { features.contains(feature) }
}

// This is an index of document JSON, never an independently editable copy of content.
nonisolated enum DocumentPreviewDescriptorIndex {
    // Bump when the descriptor computation itself changes (a new feature flag, a
    // changed detection rule), to force every descriptor — and therefore every
    // preview cache key derived from it — to rebuild on the next launch.
    static let schemaVersion = 2

    static func install(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE documentPreviewDescriptors (
                documentID TEXT PRIMARY KEY NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                contentHash TEXT NOT NULL,
                features INTEGER NOT NULL,
                pageReferenceIDs TEXT NOT NULL,
                collectionIDs TEXT NOT NULL,
                descriptorVersion INTEGER NOT NULL
            );
            CREATE TABLE previewDescriptorChanges (documentID TEXT PRIMARY KEY NOT NULL);
            CREATE TRIGGER preview_descriptor_document_insert AFTER INSERT ON documents BEGIN
                INSERT OR IGNORE INTO previewDescriptorChanges VALUES (NEW.id);
            END;
            CREATE TRIGGER preview_descriptor_document_update AFTER UPDATE OF tipTapJSON ON documents BEGIN
                INSERT OR IGNORE INTO previewDescriptorChanges VALUES (NEW.id);
            END;
            CREATE TRIGGER preview_descriptor_document_delete AFTER DELETE ON documents BEGIN
                INSERT OR IGNORE INTO previewDescriptorChanges VALUES (OLD.id);
            END;
            """)
        // No eager backfill here. Parsing every existing document body at migration
        // time would reintroduce a launch delay on the upgrade — the exact cost this
        // work exists to remove. Instead existing documents are indexed by the
        // background backfill (see `runBackfill`) after launch, in bounded batches off
        // the main thread, and until a document is indexed the gallery falls back to
        // the always-correct record path for it. New and changed documents are indexed
        // immediately by the dirty-set triggers above draining in `AppDatabase.write`.
    }

    // Drains the dirty set, rebuilding descriptors for every document whose body
    // changed since the last pass. Mirrors DocumentTaskIndex.reconcile so the two
    // indexes stay consistent in cadence and failure behavior. `limit` bounds how
    // many documents are rebuilt per call so a large backlog never blocks a single
    // save or import; returns true while work remains.
    @discardableResult
    static func reconcile(in db: Database, limit: Int? = nil) throws -> Bool {
        let documentIDs: [String]
        if let limit {
            documentIDs = try String.fetchAll(db, sql: "SELECT documentID FROM previewDescriptorChanges LIMIT ?", arguments: [limit])
        } else {
            documentIDs = try String.fetchAll(db, sql: "SELECT documentID FROM previewDescriptorChanges")
        }
        guard !documentIDs.isEmpty else { return false }

        for id in documentIDs {
            guard let document = try DocumentRecord.fetchOne(db, key: id) else {
                // The foreign key has already removed the descriptor row.
                try db.execute(sql: "DELETE FROM previewDescriptorChanges WHERE documentID = ?", arguments: [id])
                continue
            }
            let descriptor = self.descriptor(for: document)
            try write(descriptor, in: db)
            try db.execute(sql: "DELETE FROM previewDescriptorChanges WHERE documentID = ?", arguments: [id])
        }

        // Report whether more dirty rows remain so callers can continue draining.
        return try Int.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM previewDescriptorChanges)") == 1
    }

    // Indexes up to `limit` documents that do not yet have a current-version
    // descriptor — the one-time backfill after an upgrade. Returns true while more
    // documents remain, so the caller can continue in bounded batches. This is kept
    // separate from the dirty set (which tracks edits/imports) so a huge initial
    // backlog never competes with incremental reconciliation.
    @discardableResult
    static func backfillBatch(in db: Database, limit: Int) throws -> Bool {
        let ids = try String.fetchAll(db, sql: """
            SELECT id FROM documents
            WHERE id NOT IN (SELECT documentID FROM documentPreviewDescriptors WHERE descriptorVersion = ?)
            LIMIT ?
            """, arguments: [schemaVersion, limit])
        guard !ids.isEmpty else { return false }
        for id in ids {
            guard let document = try DocumentRecord.fetchOne(db, key: id) else { continue }
            try write(descriptor(for: document), in: db)
        }
        return ids.count == limit
    }

    // Documents that still lack a current-version descriptor — the backfill backlog.
    static func remainingBackfillCount(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM documents
            WHERE id NOT IN (SELECT documentID FROM documentPreviewDescriptors WHERE descriptorVersion = ?)
            """, arguments: [schemaVersion]) ?? 0
    }

    // Runs the backfill in bounded batches off the main actor, yielding between
    // batches so it never competes with interactive work. Safe to launch on every
    // start: when the index is already complete it finds nothing and exits at once.
    // Progress is reported to the console under the [Penned Migration] prefix, per
    // device, reflecting only work actually completed (measured by the backlog delta).
    static func runBackfill(_ database: AppDatabase, batchSize: Int = 48) async {
        let log = PennedDiagnostics.migration
        let device = PennedDiagnostics.deviceTag
        let start = Date()
        log.notice("[Penned Migration] (\(device, privacy: .public)) Device-local descriptor migration initializing")
        log.notice("[Penned Migration] (\(device, privacy: .public)) Descriptor schema: v\(schemaVersion, privacy: .public)")
        var remaining = (try? database.read { try remainingBackfillCount(in: $0) }) ?? 0
        let total = remaining
        log.notice("[Penned Migration] (\(device, privacy: .public)) Documents requiring backfill: \(total, privacy: .public)")
        if total == 0 {
            log.notice("[Penned Migration] (\(device, privacy: .public)) Descriptor backfill already complete; nothing to generate.")
            return
        }
        var processed = 0
        var failedBatches = 0
        while !Task.isCancelled && remaining > 0 {
            // writeMetadata writes the derived index without running the task/tag
            // reconciles or posting the change notifications a normal `write` does —
            // the backfill touches only the descriptor table, which nothing observes,
            // so each batch stays cheap and silent.
            var batchFailed = false
            let more: Bool
            do { more = try database.writeMetadata { try backfillBatch(in: $0, limit: batchSize) } }
            catch {
                batchFailed = true; more = false
                failedBatches += 1
                log.error("[Penned Migration] (\(device, privacy: .public)) Batch failed: \(error.localizedDescription, privacy: .public)")
            }
            let after = (try? database.read { try remainingBackfillCount(in: $0) }) ?? remaining
            let batch = max(0, remaining - after)
            processed += batch
            remaining = after
            if !batchFailed {
                log.notice("[Penned Migration] (\(device, privacy: .public)) Batch completed: \(batch, privacy: .public) documents")
                log.notice("[Penned Migration] (\(device, privacy: .public)) Progress: \(processed, privacy: .public)/\(total, privacy: .public)")
                log.notice("[Penned Migration] (\(device, privacy: .public)) Remaining: \(remaining, privacy: .public)")
            }
            // Stop if the backlog is not shrinking and the index reports no more work
            // (e.g. rows skipped because their record could not be read), so a stuck
            // backlog is surfaced rather than looped on forever.
            if !more && batch == 0 { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        let elapsed = Date().timeIntervalSince(start)
        if remaining == 0 {
            log.notice("[Penned Migration] (\(device, privacy: .public)) Descriptor backfill completed. Processed \(processed, privacy: .public) documents.")
        } else {
            log.notice("[Penned Migration] (\(device, privacy: .public)) Descriptor backfill stopped with \(remaining, privacy: .public) still pending (processed \(processed, privacy: .public), failed batches \(failedBatches, privacy: .public)).")
        }
        log.notice("[Penned Migration] (\(device, privacy: .public)) Duration: \(String(format: "%.2f", elapsed), privacy: .public)s")
    }

    static func write(_ descriptor: DocumentPreviewDescriptor, in db: Database) throws {
        let pageRefs = encode(descriptor.pageReferenceIDs)
        let collections = encode(descriptor.collectionIDs)
        try db.execute(sql: """
            INSERT INTO documentPreviewDescriptors(documentID, contentHash, features, pageReferenceIDs, collectionIDs, descriptorVersion)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(documentID) DO UPDATE SET contentHash = excluded.contentHash, features = excluded.features,
                pageReferenceIDs = excluded.pageReferenceIDs, collectionIDs = excluded.collectionIDs,
                descriptorVersion = excluded.descriptorVersion
            """, arguments: [descriptor.documentID, descriptor.contentHash, descriptor.features.rawValue,
                             pageRefs, collections, schemaVersion])
    }

    static func fetch(_ documentID: String, in db: Database) throws -> DocumentPreviewDescriptor? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM documentPreviewDescriptors WHERE documentID = ? AND descriptorVersion = ?",
                                         arguments: [documentID, schemaVersion]) else { return nil }
        return DocumentPreviewDescriptor(
            documentID: row["documentID"],
            contentHash: row["contentHash"],
            features: DocumentPreviewDescriptor.Features(rawValue: row["features"]),
            pageReferenceIDs: decode(row["pageReferenceIDs"]),
            collectionIDs: decode(row["collectionIDs"])
        )
    }

    // Pure computation from a document body. Every detection here mirrors a
    // corresponding presentation check in DocumentPreviewContent.cacheKey.
    static func descriptor(for document: DocumentRecord) -> DocumentPreviewDescriptor {
        let json = document.tipTapJSON
        var features: DocumentPreviewDescriptor.Features = []
        if TipTapContentAnalyzer.hasInlineProperties(in: json) { features.insert(.inlineProperties) }
        if TipTapContentAnalyzer.hasCallouts(in: json) { features.insert(.callouts) }
        if TipTapContentAnalyzer.hasListGrids(in: json) { features.insert(.listGrids) }
        if json.contains("\"codeBlock\"") { features.insert(.codeBlock) }
        if TipTapContentAnalyzer.hasGridCards(in: json) { features.insert(.gridCards) }
        if json.contains("\"presentation\":\"label\"") { features.insert(.headingLabel) }
        if json.contains("\"presentation\":\"label\"") && json.contains("\"style\":\"textured\"") { features.insert(.texturedLabel) }
        if ["shape", "style"].contains(where: { key in
            json.contains("\"\(key)\":\"plaque\"") || json.contains("\"\(key)\":\"banner\"")
        }) { features.insert(.decorativeLabel) }
        if json.contains("\"tabs\"") { features.insert(.tabs) }
        if json.contains("\"minimalFields\"") { features.insert(.minimalFields) }
        if TipTapContentAnalyzer.hasFourDotDivider(in: json) { features.insert(.fourDotDivider) }
        if TemplateComponentDefinition.contains(in: json) { features.insert(.templateComponent) }
        if !EditorAttachment.paths(in: json).isEmpty { features.insert(.attachment) }
        if TipTapContentAnalyzer.hasInlineTags(in: json) { features.insert(.inlineTags) }
        if TipTapContentAnalyzer.hasToggles(in: json) { features.insert(.toggles) }
        if TipTapContentAnalyzer.hasClipSources(in: json) { features.insert(.clipSources) }
        if json.contains("\"table\"") { features.insert(.table) }
        if json.contains("\"blockquote\"") { features.insert(.blockquote) }
        if json.contains("\"informationCard\"") { features.insert(.informationCard) }
        if json.contains("\"richLink\"") { features.insert(.richLink) }

        return DocumentPreviewDescriptor(
            documentID: document.id,
            contentHash: contentHash(for: json),
            features: features,
            pageReferenceIDs: TipTapContentAnalyzer.pageReferenceIDs(in: json),
            collectionIDs: TipTapContentAnalyzer.collectionIDs(in: json)
        )
    }

    static func contentHash(for json: String) -> String {
        SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func encode(_ ids: Set<String>) -> String {
        let data = (try? JSONEncoder().encode(ids.sorted())) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode(_ string: String) -> Set<String> {
        guard let data = string.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(values)
    }
}
