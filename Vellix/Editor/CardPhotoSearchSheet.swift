import SwiftUI

struct CardPhotoSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    var select: (CardRemotePhoto) -> Void
    @State private var query = ""
    @State private var photos: [CardRemotePhoto] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var requestID = UUID()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image("searchwavy").renderingMode(.template).resizable().scaledToFit().frame(width: 18, height: 18).foregroundStyle(.secondary)
                    TextField("Search Unsplash", text: $query).textFieldStyle(.plain)
                }.padding(12).pennedSheetField().padding(.horizontal)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 14) {
                        ForEach(photos) { photo in
                            VStack(alignment: .leading, spacing: 5) {
                                Button { select(photo); dismiss() } label: {
                                    GeometryReader { proxy in
                                        AsyncImage(url: URL(string: photo.thumbURL)) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.05) }
                                            .frame(width: proxy.size.width, height: 115).clipped()
                                    }.frame(height: 115).clipShape(RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain).accessibilityLabel("Select photo by \(photo.photographer)")
                                CardPhotoCredit(photo: photo, compact: true)
                            }
                        }
                    }.padding(.horizontal)
                    if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.secondary).padding() }
                    if hasMore && !loading { Button("Load More") { Task { await load(next: true) } }.padding() }
                }
            }
            .navigationTitle("Unsplash")
            .pennedSheet(title: "Unsplash", close: { dismiss() })
            .task(id: query) {
                requestID = UUID()
                hasMore = false
                loading = false
                do { try await Task.sleep(for: .milliseconds(350)); await load(next: false) }
                catch {}
            }
        }
    }

    private func load(next: Bool) async {
        let token = UUID()
        requestID = token
        let searchQuery = query
        loading = true
        errorMessage = nil
        defer { if requestID == token { loading = false } }
        let target = next ? page + 1 : 1
        do {
            let result = try await CardPhotoService().search(query: searchQuery, page: target)
            guard !Task.isCancelled, requestID == token, query == searchQuery else { return }
            page = target
            hasMore = result.hasMore
            if next { let ids = Set(photos.map(\.id)); photos += result.photos.filter { !ids.contains($0.id) } }
            else { photos = result.photos }
        } catch { if !Task.isCancelled && requestID == token { errorMessage = error.localizedDescription } }
    }
}
