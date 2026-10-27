// Mac-target platform adapter. Based on Vellix/DailyNotes/DailyNotesSettingsView.swift.
// iPhone/iPad implementations remain in their original target.
import SwiftUI

struct DailyNotesSettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    var onSelected: (() -> Void)?
    var isWorkspaceEmbedded = false
    @State private var selectedID: String?
    @State private var error: String?
    @State private var query = ""
    private var matchingTemplates: [TemplateRecord] {
        environment.overview.templates.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 12) {
            if onSelected != nil || isWorkspaceEmbedded { PennedSheetSearchField(text: $query, prompt: "Templates").padding(.horizontal, 20) }
            templateList
        }
        .navigationTitle("Daily Notes")
        .tint(onSelected == nil ? VellixSurface.accent : PennedSheetStyle.accent)
        .onAppear(perform: load)
        .onChange(of: environment.selectedSpaceID) { _, _ in load() }
        .onChange(of: environment.overview.templates) { _, _ in load() }
    }

    private var templateList: some View {
        List {
            Section("Default Template") {
                if let template = environment.overview.templates.first(where: { $0.id == selectedID }) {
                    Text(template.title).fontWeight(.semibold).pennedSheetRows(showsSeparator: true, when: onSelected != nil)
                    Button("Clear Selection", role: .destructive) { select(nil) }
                } else { Text("No template selected").foregroundStyle(.secondary) }
            }.pennedSheetRows(when: onSelected != nil)
            Section("Templates in This Space") {
                ForEach(matchingTemplates) { template in
                    Button { select(template.id) } label: {
                        HStack(spacing: 12) {
                            if let document = environment.overview.templateDocuments[template.id] {
                                NestedPageThumbnail(json: document.tipTapJSON, title: document.title, appearance: document.appearance,
                                    size: CGSize(width: 31, height: 40), cover: document.cover, attachmentStore: environment.attachmentStore)
                            }
                            Text(template.title).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                            if selectedID == template.id {
                                LibraryIcon(name: "checkwavy", size: 18)
                                    .foregroundStyle(onSelected == nil ? VellixSurface.accent : PennedSheetStyle.accent)
                            }
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .disabled(template.rootDocumentID != nil && environment.overview.templateDocuments[template.id] == nil)
                    .accessibilityAddTraits(selectedID == template.id ? .isSelected : [])
                    .pennedSheetRows(showsSeparator: template.id != matchingTemplates.last?.id, when: onSelected != nil)
                }
                if environment.overview.templates.isEmpty {
                    Button("Create Template") {
                        environment.isSettingsPresented = false
                        dismiss()
                        environment.createTemplate()
                    }
                }
            }.pennedSheetRows(when: onSelected != nil)
            if let error { Section { Text(error).foregroundStyle(.red) }.pennedSheetRows(when: onSelected != nil) }
        }
        .dailyNoteTemplateSearch(text: $query, isSheet: onSelected != nil || isWorkspaceEmbedded)
    }

    private func load() {
        do { selectedID = try environment.dailyNotes.defaultTemplate()?.id; error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func select(_ id: String?) {
        do {
            try environment.dailyNotes.setDefaultTemplate(id)
            selectedID = id; error = nil
            if id != nil { onSelected?() }
        } catch { self.error = error.localizedDescription }
    }
}

private extension View {
    @ViewBuilder func dailyNoteTemplateSearch(text: Binding<String>, isSheet: Bool) -> some View {
        if isSheet { self }
        else { searchable(text: text, prompt: "Templates") }
    }
}
