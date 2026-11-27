import Foundation

// Source only. Nothing starts until explicitly instantiated by the future integration.
nonisolated public struct RailwayHTTPResult: Sendable {
    public let data: Data
    public let status: Int
    public let headers: [String:String]
}
nonisolated private final class RailwayNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session:URLSession, task:URLSessionTask, willPerformHTTPRedirection response:HTTPURLResponse, newRequest request:URLRequest, completionHandler:@escaping @Sendable (URLRequest?)->Void) { completionHandler(nil) }
}
public actor RailwayTransport {
    private let base: URL
    private let session: URLSession
    public init(baseURL:URL, allowsCellular:Bool = true, allowsExpensive:Bool = true, allowsConstrained:Bool = true,requestTimeout:TimeInterval=60) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil, ["","/"].contains(baseURL.path) else { throw RailwayError.invalidConfiguration }
        base = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.allowsCellularAccess = allowsCellular; config.allowsExpensiveNetworkAccess = allowsExpensive; config.allowsConstrainedNetworkAccess = allowsConstrained
        config.timeoutIntervalForRequest = requestTimeout; config.timeoutIntervalForResource = 600
        session = URLSession(configuration:config,delegate:RailwayNoRedirects(),delegateQueue:nil)
    }
    public nonisolated static func validateSegment(_ value:String) throws {
        guard !value.isEmpty, value != ".", value != "..", value.utf8.count <= 1024,
              !value.contains("/"), !value.contains("\\"), !value.contains("%"), !value.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { throw RailwayError.invalidParameter }
    }
    private func request(_ method:String,_ path:[String],query:[URLQueryItem],token:String?,contentType:String?,headers:[String:String]) throws -> URLRequest {
        var url = base
        for item in path { try Self.validateSegment(item); url.appendPathComponent(item) }
        guard var components = URLComponents(url:url,resolvingAgainstBaseURL:false) else { throw RailwayError.invalidConfiguration }
        if !query.isEmpty { components.queryItems = query }
        guard let target = components.url else { throw RailwayError.invalidParameter }
        var request = URLRequest(url:target); request.httpMethod = method
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        if let token { request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization") }
        if let contentType { request.setValue(contentType,forHTTPHeaderField:"Content-Type") }
        for (key,value) in headers {
            guard ["idempotency-key","prefer","if-match","accept","apikey"].contains(key.lowercased()), !value.contains("\r"), !value.contains("\n") else { throw RailwayError.invalidParameter }
            request.setValue(value,forHTTPHeaderField:key)
        }
        return request
    }
    private func check(_ response:URLResponse,data:Data) throws -> RailwayHTTPResult {
        guard let h = response as? HTTPURLResponse else { throw RailwayError.invalidResponse }
        if !(200..<300).contains(h.statusCode) {
            let e = try? JSONDecoder().decode(RailwayJSON.self,from:data)
            throw RailwayError.http(h.statusCode,e?["error"]?["code"]?.string,e?["error"]?["requestId"]?.string)
        }
        return .init(data:data,status:h.statusCode,headers:h.allHeaderFields.reduce(into:[String:String]()){$0[String(describing:$1.key).lowercased()]=String(describing:$1.value)})
    }
    public func send(_ method:String,_ path:[String],query:[URLQueryItem]=[],token:String?=nil,body:RailwayJSON?=nil,headers:[String:String]=[:]) async throws -> RailwayHTTPResult {
        var req = try request(method,path,query:query,token:token,contentType:body == nil ? nil : "application/json",headers:headers)
        if let body { req.httpBody = try RailwayJSON.encoder.encode(body) }
        let (data,response) = try await session.data(for:req)
        return try check(response,data:data)
    }
    public func json<T:Decodable & Sendable>(_ type:T.Type, _ method:String,_ path:[String],query:[URLQueryItem]=[],token:String?=nil,body:RailwayJSON?=nil,headers:[String:String]=[:]) async throws -> T {
        let result = try await send(method,path,query:query,token:token,body:body,headers:headers)
        return try JSONDecoder().decode(type,from:result.data)
    }
    public func upload(_ path:[String],query:[URLQueryItem],token:String,bodyFile:URL,contentType:String,method:String="POST",headers:[String:String]=[:]) async throws -> RailwayHTTPResult {
        let req = try request(method,path,query:query,token:token,contentType:contentType,headers:headers)
        let (data,response) = try await session.upload(for:req,fromFile:bodyFile)
        return try check(response,data:data)
    }
    public func download(_ path:[String],query:[URLQueryItem],token:String,headers:[String:String]=[:],staging:URL) async throws -> RailwayHTTPResult {
        let req = try request("GET",path,query:query,token:token,contentType:nil,headers:headers)
        let (temporary,response) = try await session.download(for:req)
        guard let h = response as? HTTPURLResponse else { throw RailwayError.invalidResponse }
        if !(200..<300).contains(h.statusCode) {
            let handle = try FileHandle(forReadingFrom:temporary); defer { try? handle.close() }
            return try check(response,data:handle.read(upToCount:65536) ?? Data())
        }
        try FileManager.default.moveItem(at:temporary,to:staging)
        return try check(response,data:Data())
    }
    public func socket(_ path:[String],token:String) throws -> URLSessionWebSocketTask {
        var req = try request("GET",path,query:[],token:token,contentType:nil,headers:[:])
        guard let url = req.url, var components = URLComponents(url:url,resolvingAgainstBaseURL:false) else { throw RailwayError.invalidConfiguration }
        components.scheme = "wss"; req.url = components.url
        let socket = session.webSocketTask(with:req); socket.resume(); return socket
    }
}
