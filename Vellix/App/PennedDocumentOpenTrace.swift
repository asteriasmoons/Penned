import Foundation
import os

@MainActor
struct PennedDocumentOpenTrace {
    #if DEBUG && os(iOS)
    static let enabled = true
    #else
    static let enabled = false
    #endif

    private static let logger = Logger(subsystem: "im.lystaria.Vellix", category: "DocumentOpeningTrace")
    private let tapID = UUID()
    private let started = ProcessInfo.processInfo.systemUptime
    let documentID: String
    let source: String
    private(set) var requestID: UUID?

    init(documentID: String, source: String) {
        self.documentID = documentID
        self.source = source
    }

    func accepted(requestID: UUID) -> Self {
        var trace = self
        trace.requestID = requestID
        return trace
    }

    @discardableResult
    func event(_ name: String, _ fields: @autoclosure () -> String = "", since start: TimeInterval? = nil) -> TimeInterval {
        guard Self.enabled else { return 0 }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = Int((now - started) * 1_000)
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let duration = start.map { " duration=\(Int((now - $0) * 1_000))ms" } ?? ""
        let details = fields()
        Self.logger.notice("[Penned Document Open] ts=\(timestamp, privacy: .public) tap=\(tapID.uuidString, privacy: .public) request=\(requestID?.uuidString ?? "-", privacy: .public) document=\(documentID, privacy: .public) source=\(source, privacy: .public) event=\(name, privacy: .public) elapsed=\(elapsed, privacy: .public)ms\(duration, privacy: .public) \(details, privacy: .public)")
        return now
    }

    static func errorCode(_ error: Error?) -> String {
        guard let error else { return "none" }
        let value = error as NSError
        return "\(value.domain == WKErrorDomainName ? "WebKit" : "other"):\(value.code)"
    }

    private static let WKErrorDomainName = "WKErrorDomain"
}
