import Foundation
import Testing
@testable import Vellix

@MainActor
struct AttachmentBridgeTests {
    @Test func fileLongPressRequestsActionsInsteadOfOpeningSettings() throws {
        let payload: [String: Any] = ["blockID": "block", "relativePath": "divider.png", "mode": "inline", "width": 60.0, "alignment": "center"]
        let actions = try TipTapEditorEvent(kind: "attachmentActions", payload: payload)
        let settings = try TipTapEditorEvent(kind: "attachmentMenu", payload: payload)
        guard case .requestAttachmentActions(let actionRequest) = actions,
              case .requestAttachment(let settingsRequest) = settings else {
            Issue.record("Long press must expose actions while tapping retains file settings"); return
        }
        #expect(actionRequest == settingsRequest)
        #expect(actionRequest.blockID == "block" && actionRequest.relativePath == "divider.png")
    }

    @Test func fileRequestsRetainBytesAndRejectMalformedPayloads() throws {
        let data = Data("File contents".utf8)
        let event = try TipTapEditorEvent(kind: "attachmentImport", payload: ["token": "insert", "files": [["name": "note.txt", "mimeType": "text/plain", "base64": data.base64EncodedString()]]])
        guard case .importAttachments(let token, let files) = event else { Issue.record("Missing file import event"); return }
        #expect(token == "insert" && files.first?.data == data)
        let invalid = try TipTapEditorEvent(kind: "attachmentImport", payload: ["token": "insert", "files": [["base64": "invalid!"]]])
        guard case .editorError = invalid else { Issue.record("Malformed bytes must not import"); return }
    }
}
