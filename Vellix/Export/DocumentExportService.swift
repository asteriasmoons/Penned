import Foundation
import SwiftUI
import Combine
import GRDB

@MainActor
enum DocumentExportService {
    static func generate(documentID: String, format: DocumentExportFormat, settings: DocumentExportSettings,
                         environment: AppEnvironment, scheme: ColorScheme,
                         progress: @escaping (String) -> Void) async throws -> DocumentExportOutput {
        progress("Preparing saved document")
        let snapshot = try await DocumentExportSnapshot.capture(documentID: documentID, environment: environment, includeNested: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PennedExports", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        let output: DocumentExportOutput
        switch format {
        case .pdf, .print, .image:
            let renderer = DocumentExportRenderer(snapshot: snapshot, store: environment.attachmentStore, scheme: scheme)
            output = try await renderer.render(format: format, settings: settings, directory: directory, progress: progress)
        case .word:
            progress("Writing Word document")
            var writer = DocumentWordExport(snapshot: snapshot, settings: settings)
            let file = directory.appendingPathComponent(DocumentExportNames.filename(snapshot.root.title) + ".docx")
            try writer.write(to: file)
            output = DocumentExportOutput(format: format, files: [file], warnings: snapshot.warnings, directory: directory)
        case .markdown, .textBundle:
            progress("Writing Markdown and assets")
            let markdown = DocumentMarkdownExport(snapshot: snapshot, settings: settings).text()
            let name = DocumentExportNames.filename(snapshot.root.title)
            let package = format == .textBundle ? directory.appendingPathComponent(name + ".textbundle", isDirectory: true) : directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: package.appendingPathComponent("assets", isDirectory: true), withIntermediateDirectories: true)
            let text = package.appendingPathComponent(format == .textBundle ? "text.markdown" : name + ".md")
            try Data(markdown.utf8).write(to: text, options: .atomic)
            for (path, source) in snapshot.assets {
                try Task.checkCancellation()
                try FileManager.default.copyItem(at: source, to: package.appendingPathComponent("assets").appendingPathComponent(snapshot.assetFilename(path)))
            }
            if format == .textBundle {
                let info: [String: Any] = ["version": 2, "type": "net.daringfireball.markdown", "transient": false, "creatorIdentifier": Bundle.main.bundleIdentifier ?? "im.lystaria.Vellix"]
                try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]).write(to: package.appendingPathComponent("info.json"), options: .atomic)
            }
            let archive = directory.appendingPathComponent(name + (format == .textBundle ? ".textpack" : ".zip"))
            var entries = try archiveEntries(in: package, prefix: format == .textBundle ? name + ".textbundle/" : name + "/")
            if format == .textBundle { entries.append(.init(name + ".textbundle/assets/", data: Data())) }
            try DocumentExportArchive.write(entries, to: archive)
            let files: [URL]
            if format == .textBundle { files = [archive] }
            else if snapshot.assets.isEmpty { files = [text] }
            else { files = [text, archive] }
            output = DocumentExportOutput(format: format, files: files, previewText: markdown, warnings: snapshot.warnings, directory: directory)
        default: throw DocumentExportError.failed("Choose an export format.")
        }
        try Task.checkCancellation()
        guard environment.database.libraryID == snapshot.libraryID, environment.selectedSpaceID == snapshot.spaceID,
              !environment.isSwitchingSpace else { throw LibraryError.staleWorkspace }
        complete = true
        return output
    }

    static func archiveEntries(in directory: URL, prefix: String = "") throws -> [DocumentExportArchive.Entry] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { throw DocumentExportError.failed("The export package could not be read.") }
        var entries: [DocumentExportArchive.Entry] = []
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                entries.append(.init(prefix + String(file.path.dropFirst(directory.path.count + 1)), file: file))
            }
        }
        return entries.sorted { $0.name < $1.name }
    }

    static func shareArchive(_ output: DocumentExportOutput) throws -> URL {
        if output.files.count == 1, let file = output.files.first { return file }
        // Markdown's archive already contains its text and all companion assets.
        if let archive = output.files.first(where: { $0.pathExtension == "zip" }) { return archive }
        let url = output.directory.appendingPathComponent("Images.zip")
        try DocumentExportArchive.write(output.files.map { .init($0.lastPathComponent, file: $0) }, to: url)
        return url
    }

    static func duplicate(documentID: String, destinationSpaceID: String?, sameLocation: Bool, environment: AppEnvironment) async throws -> DocumentRecord {
        let snapshot = try await DocumentExportSnapshot.capture(documentID: documentID, environment: environment, includeNested: true)
        var paths: [String] = []
        do {
            let copy: DocumentRecord
            if sameLocation { copy = try environment.documents.duplicate(id: documentID, attachmentStore: environment.attachmentStore) }
            else {
                guard let destinationSpaceID else { throw LibraryError.staleWorkspace }
                copy = try environment.database.write { db in
                    try SpaceOwnership.requireSpace(destinationSpaceID, in: db)
                    let source = try SpaceOwnership.document(documentID, scope: snapshot.spaceID, in: db)
                    let result = try TemplateRepository(database: environment.database).cloneTree(sourceID: source.id,
                        title: source.title + " Copy", templateID: nil, originID: nil, spaceID: destinationSpaceID,
                        folderID: nil, parentID: nil, store: environment.attachmentStore, paths: &paths, in: db)
                    if let context = snapshot.contents[documentID]?.entryContext {
                        // A root copy cannot remain a member of a collection in
                        // another location. Keep its values as independent properties.
                        var object = TipTapContentAnalyzer.documentObject(from: result.tipTapJSON)
                        let properties = try context.0.fields.map { field -> [String: Any] in
                            var definition = (context.1.values[field.id] ?? CollectionValue()).applying(to: field.configuration)
                            let ids = Dictionary(uniqueKeysWithValues: definition.options.map { ($0.id, UUID().uuidString) })
                            definition.selectedOptionIDs = definition.selectedOptionIDs.compactMap { ids[$0] }
                            for index in definition.options.indices { definition.options[index].id = ids[definition.options[index].id] ?? UUID().uuidString }
                            return ["type": "inlineProperty", "attrs": ["id": UUID().uuidString, "property": try definition.bridgeObject()]]
                        }
                        object["content"] = properties + (object["content"] as? [[String: Any]] ?? [])
                        let repository = DocumentRepository(database: environment.database)
                        repository.spaceID = destinationSpaceID
                        let json = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
                        return try repository.saveEditorJSON(id: result.id, canonicalJSON: json, in: db)
                    }
                    return result
                }
            }
            environment.refresh(); environment.collections.refresh()
            return copy
        } catch {
            for path in paths { try? environment.attachmentStore.removeFile(relativePath: path) }
            throw error
        }
    }
}

@MainActor
final class DocumentExportController: ObservableObject {
    @Published private(set) var output: DocumentExportOutput?
    @Published private(set) var busy = false
    @Published private(set) var progress = ""
    @Published private(set) var error: String?
    private var operation: Task<Void, Never>?
    private var generation = UUID()

    func generate(documentID: String, format: DocumentExportFormat, settings: DocumentExportSettings, environment: AppEnvironment, scheme: ColorScheme) {
        operation?.cancel(); generation = UUID()
        let token = generation
        busy = true; error = nil; output = nil
        operation = Task {
            do {
                let value = try await DocumentExportService.generate(documentID: documentID, format: format, settings: settings, environment: environment, scheme: scheme) { [weak self] value in
                    if self?.generation == token { self?.progress = value }
                }
                guard !Task.isCancelled, generation == token else { return }
                output = value; busy = false
            } catch {
                guard generation == token else { return }
                busy = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func cancel() { operation?.cancel(); operation = nil; generation = UUID(); busy = false }
}
