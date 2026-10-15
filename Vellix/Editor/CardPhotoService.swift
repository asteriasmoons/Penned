import Foundation

struct CardPhotoSearchResult: Decodable {
    var photos: [CardRemotePhoto]
    var hasMore: Bool
}

struct CardPhotoService {
    var baseURL = URL(string: "https://appapi.voxiverse.ink/api/vellix/photos")!
    var session = URLSession.shared

    func search(query: String = "", page: Int = 1, shuffle: Bool = false) async throws -> CardPhotoSearchResult {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "page", value: String(page)),
                                 URLQueryItem(name: "shuffle", value: String(shuffle))]
        return try await request(URLRequest(url: components.url!))
    }

    func trackSelection(_ photo: CardRemotePhoto) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(photo.id).appendingPathComponent("selection"))
        request.httpMethod = "POST"
        let _: SelectionResult = try await self.request(request)
    }

    private struct SelectionResult: Decodable { var success: Bool }
    private struct APIError: Decodable { var error: String }
    private func request<T: Decodable>(_ request: URLRequest) async throws -> T {
        var request = request
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let error = (try? JSONDecoder().decode(APIError.self, from: data))?.error ?? "Photo search is unavailable. Please try again."
            throw NSError(domain: "VellixPhotos", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
