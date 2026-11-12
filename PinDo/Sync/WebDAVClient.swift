import Foundation

struct SyncConnection: Codable, Equatable, Sendable {
    var server: String
    var directory: String
    var username: String
    var root: URL {
        get throws {
            guard let parts = URLComponents(string: server.trimmingCharacters(in: .whitespacesAndNewlines)), parts.scheme == "https",
                  parts.host != nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  let base = parts.url, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SyncFailure.configuration("请输入 HTTPS WebDAV 地址和账号。")
            }
            let directory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            let components = directory.split(separator: "/").map(String.init)
            guard !components.isEmpty, !directory.contains("\\"), !directory.contains("%"),
                  components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains(":") && !$0.contains(where: { $0.isNewline }) }) else {
                throw SyncFailure.configuration("请手动填写专用同步目录，例如 PinDo。目录不能留空或包含 ..、百分号、反斜杠。")
            }
            return components.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
        }
    }
    var credentialKey: String { SyncCodec.hash(Data((server + "\n" + directory + "\n" + username).utf8)) }
}
struct DAVResponse: Sendable {
    let data: Data
    let status: Int
    let etag: String?
}
protocol DAVTransport: Sendable {
    func request(_ method: String, path: String, body: Data?, headers: [String: String]) async throws -> DAVResponse
    func children(_ path: String) async throws -> [String]
}

private final class DAVRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Do not forward application passwords to redirect targets.
        completionHandler(nil)
    }
}
actor WebDAVClient: DAVTransport {
    let root: URL
    private let authorization: String
    private let session: URLSession
    init(connection: SyncConnection, password: String) throws {
        root = try connection.root
        guard !password.isEmpty else { throw SyncFailure.configuration("请输入坚果云的应用授权密码。") }
        authorization = "Basic " + Data((connection.username + ":" + password).utf8).base64EncodedString()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 90
        config.httpCookieStorage = nil; config.urlCache = nil
        session = URLSession(configuration: config, delegate: DAVRedirectPolicy(), delegateQueue: nil)
    }
    func request(_ method: String, path: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> DAVResponse {
        guard !path.hasPrefix("/"), !path.contains(".."), !path.contains("%"), !path.contains("\\") else { throw SyncFailure.invalidData }
        let url = path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = method; request.httpBody = body
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if body != nil { request.setValue(method == "PROPFIND" ? "application/xml; charset=utf-8" : "application/json", forHTTPHeaderField: "Content-Type") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 64 * 1024 * 1024 else { throw SyncFailure.invalidData }
        if [429, 503].contains(http.statusCode), let retry = http.value(forHTTPHeaderField: "Retry-After") {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let seconds = Double(retry) ?? formatter.date(from: retry)?.timeIntervalSinceNow ?? 60
            throw SyncFailure.throttled(max(1, seconds))
        }
        return DAVResponse(data: data, status: http.statusCode, etag: http.value(forHTTPHeaderField: "ETag"))
    }
    func children(_ path: String) async throws -> [String] {
        let body = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>".utf8)
        let response = try await request("PROPFIND", path: path, body: body, headers: ["Depth": "1"])
        guard response.status == 207 else { throw SyncFailure.http(response.status) }
        let target = path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1), isDirectory: true) }
        return try DAVListing.parse(response.data, directory: target)
    }
}

final class DAVListing: NSObject, XMLParserDelegate {
    private var hrefs: [String] = []
    private var text = ""
    private var inHref = false
    private var inStatus = false
    private var multistatus = false
    private var invalid = false
    private var responseCount = 0
    static func parse(_ data: Data, directory: URL) throws -> [String] {
        // Reject external entities/DTDs before parsing untrusted XML.
        guard let xml = String(data: data, encoding: .utf8), !xml.uppercased().contains("<!DOCTYPE"), !xml.uppercased().contains("<!ENTITY") else { throw SyncFailure.invalidData }
        let delegate = DAVListing(), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, delegate.multistatus, delegate.responseCount > 0 else { throw SyncFailure.invalidData }
        guard delegate.responseCount < 750 else { throw SyncFailure.incompleteListing }
        let parent = directory.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var result = Set<String>()
        for href in delegate.hrefs {
            guard let url = URL(string: href, relativeTo: directory)?.absoluteURL, url.scheme == directory.scheme,
                  url.host == directory.host, url.port == directory.port, url.user == nil, url.query == nil, url.fragment == nil else { throw SyncFailure.invalidData }
            let path = url.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path == parent { continue }
            guard path.hasPrefix(parent + "/") else { throw SyncFailure.invalidData }
            let child = String(path.dropFirst(parent.count + 1))
            guard !child.isEmpty, !child.contains("/") else { throw SyncFailure.invalidData }
            result.insert(child)
        }
        return result.sorted()
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "multistatus", namespaceURI == "DAV:" { multistatus = true }
        if elementName == "error" { invalid = true }
        if elementName == "status" { inStatus = true; text = "" }
        if elementName == "response" { responseCount += 1 }
        if elementName == "href" { inHref = true; text = "" }
        if elementName == "limit" || elementName == "number-of-matches-within-limits" { invalid = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inHref || inStatus { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "href" { hrefs.append(text.trimmingCharacters(in: .whitespacesAndNewlines)); inHref = false }
        if elementName == "status" {
            let pieces = text.split(whereSeparator: { $0.isWhitespace })
            if pieces.count < 2 || pieces[1] != "200" { invalid = true }
            inStatus = false
        }
    }
}

extension DAVTransport {
    func get(_ path: String) async throws -> DAVResponse { try await request("GET", path: path, body: nil, headers: [:]) }
    func directory(_ path: String) async throws {
        let response = try await request("MKCOL", path: path, body: nil, headers: [:])
        guard [201, 405].contains(response.status) else { throw SyncFailure.http(response.status) }
    }
    func create(_ path: String, data: Data) async throws {
        let response = try await request("PUT", path: path, body: data, headers: ["If-None-Match": "*"])
        guard [200, 201, 204, 412].contains(response.status) else { throw SyncFailure.http(response.status) }
        let verified = try await get(path)
        guard verified.status == 200, verified.data == data else { throw SyncFailure.identityCollision }
    }
    func probe() async throws {
        let path = "probe-" + UUID().uuidString.lowercased() + ".json"
        let a = Data("{\"probe\":1}".utf8), b = Data("{\"probe\":2}".utf8)
        do {
        try await create(path, data: a)
        let original = try await get(path)
        guard let tag = original.etag, !tag.hasPrefix("W/") else { throw SyncFailure.unsafeServer }
        let collision = try await request("PUT", path: path, body: b, headers: ["If-None-Match": "*"])
        let wrong = try await request("PUT", path: path, body: b, headers: ["If-Match": "\"pindo-invalid-tag\""])
        guard collision.status == 412, wrong.status == 412 else { throw SyncFailure.unsafeServer }
        let updated = try await request("PUT", path: path, body: b, headers: ["If-Match": tag])
        guard [200, 204].contains(updated.status) else { throw SyncFailure.unsafeServer }
        let verified = try await get(path)
        guard verified.data == b, let newTag = verified.etag, !newTag.hasPrefix("W/") else { throw SyncFailure.unsafeServer }
        let removed = try await request("DELETE", path: path, body: nil, headers: ["If-Match": newTag])
        guard [200, 204].contains(removed.status) else { throw SyncFailure.http(removed.status) }
        } catch {
            // Only our unique disposable probe, and only while it still has our known contents.
            if let current = try? await get(path), current.status == 200, current.data == a || current.data == b, let tag = current.etag {
                _ = try? await request("DELETE", path: path, body: nil, headers: ["If-Match": tag])
            }
            throw error
        }
    }
}
