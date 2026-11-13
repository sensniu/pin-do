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
    var collectionURLs: [URL] {
        get throws {
            _ = try root
            var current = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines))!
            return directory.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").map {
                current.appendPathComponent(String($0), isDirectory: true)
                return current
            }
        }
    }
}
struct DAVResponse: Sendable {
    let data: Data
    let status: Int
    let etag: String?
}
enum DAVCreationMode: String, Codable, Sendable { case conditionalPut, exclusiveMove }

protocol DAVTransport: Sendable {
    func request(_ method: String, path: String, body: Data?, headers: [String: String]) async throws -> DAVResponse
    func children(_ path: String) async throws -> [String]
    func create(_ path: String, data: Data) async throws
    func moveExclusive(_ source: String, to destination: String) async throws -> DAVResponse
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
    private let collections: [URL]
    private var creationMode: DAVCreationMode?
    private let installationID: UUID
    private var creating = false
    init(connection: SyncConnection, password: String, configuration: URLSessionConfiguration = .ephemeral, creationMode: DAVCreationMode? = nil, installationID: UUID = UUID()) throws {
        root = try connection.root
        collections = try connection.collectionURLs
        self.creationMode = creationMode
        self.installationID = installationID
        guard !password.isEmpty else { throw SyncFailure.configuration("请输入坚果云的应用授权密码。") }
        authorization = "Basic " + Data((connection.username + ":" + password).utf8).base64EncodedString()
        let config = configuration
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 90
        config.httpCookieStorage = nil; config.urlCache = nil
        session = URLSession(configuration: config, delegate: DAVRedirectPolicy(), delegateQueue: nil)
    }
    @discardableResult
    func probe() async throws -> DAVCreationMode {
        try await directory("_work")
        let mode = try await DAVProbe.verify(self, prefix: "_work/" + installationID.uuidString.lowercased() + ".probe", owner: installationID)
        creationMode = mode
        return mode
    }

    func moveExclusive(_ source: String, to destination: String) async throws -> DAVResponse {
        guard !destination.hasPrefix("/"), !destination.contains(".."), !destination.contains("%"), !destination.contains("\\") else { throw SyncFailure.invalidData }
        let target = destination.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
        return try await request("MOVE", path: source, headers: ["Destination": target.absoluteString, "Overwrite": "F"])
    }

    func create(_ path: String, data: Data) async throws {
        guard !creating else { throw SyncFailure.configuration("同一设备正在创建同步文件，请稍后重试。") }
        creating = true; defer { creating = false }
        if creationMode == nil { try await probe() }
        switch creationMode! {
        case .conditionalPut: try await DAVProbe.conditionalCreate(self, path: path, data: data)
        case .exclusiveMove:
            try await directory("_work")
            try await DAVProbe.moveCreate(self, path: path, data: data, staging: SyncWorkFile(owner: installationID, data: data, kind: .payload).path)
        }
    }
    /// Only configured descendants of the server endpoint are created; never the account root itself.
    func prepareRootHierarchy() async throws {
        for url in collections {
            let response = try await perform("MKCOL", url: url, body: nil, headers: [:])
            if response.status == 201 { continue }
            guard response.status == 405 else { throw SyncFailure.http(response.status) }
            let check = try await perform("PROPFIND", url: url, body: DAVListing.collectionRequest, headers: ["Depth": "0"])
            guard check.status == 207, DAVListing.isCollection(check.data) else { throw SyncFailure.configuration("同步目录中的某一级不是可用的 WebDAV 文件夹。") }
        }
    }
    func request(_ method: String, path: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> DAVResponse {
        guard !path.hasPrefix("/"), !path.contains(".."), !path.contains("%"), !path.contains("\\") else { throw SyncFailure.invalidData }
        // DAV collections use a trailing slash, avoiding canonicalization redirects on strict servers.
        let collection = method == "MKCOL" || method == "PROPFIND"
        let url = path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1), isDirectory: collection) }
        return try await perform(method, url: url, body: body, headers: headers)
    }
    private func perform(_ method: String, url: URL, body: Data?, headers: [String: String]) async throws -> DAVResponse {
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
    static let collectionRequest = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>".utf8)
    private var hrefs: [String] = []
    private var text = ""
    private var inHref = false
    private var inStatus = false
    private var multistatus = false
    private var invalid = false
    private var responseCount = 0
    private var collection = false
    static func isCollection(_ data: Data) -> Bool {
        guard let xml = String(data: data, encoding: .utf8), !xml.uppercased().contains("<!DOCTYPE"), !xml.uppercased().contains("<!ENTITY") else { return false }
        let delegate = DAVListing(), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        return parser.parse() && delegate.multistatus && !delegate.invalid && delegate.responseCount == 1 && delegate.collection
    }
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
        if elementName == "collection", namespaceURI == "DAV:" { collection = true }
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
        if response.status == 405 {
            let check = try await request("PROPFIND", path: path, body: DAVListing.collectionRequest, headers: ["Depth": "0"])
            guard check.status == 207, DAVListing.isCollection(check.data) else { throw SyncFailure.configuration("同步路径已存在，但不是可用的 WebDAV 文件夹。") }
        }
    }
    func create(_ path: String, data: Data) async throws {
        try await DAVProbe.conditionalCreate(self, path: path, data: data)
    }
    func moveExclusive(_ source: String, to destination: String) async throws -> DAVResponse {
        throw SyncFailure.serverCapability(stage: "安全创建", detail: "服务器未提供不覆盖目标的 MOVE 操作。", status: nil)
    }
    @discardableResult
    func probe() async throws -> DAVCreationMode { try await DAVProbe.verify(self) }
    /// Call only after business publication and index confirmation, or for a verified disposable upload.
    /// Content-addressed URLs are never reused for different bytes, so DELETE need not implement CAS.
    @discardableResult
    func deleteWorkFile(_ path: String, response: DAVResponse) async throws -> Bool {
        guard let file = SyncWorkFile(path: path) else { throw SyncFailure.invalidData }
        if response.status == 404 { return true }
        guard response.status == 200 else { throw SyncFailure.http(response.status) }
        try file.validate(response.data)
        return try await deleteDisposable(path, response: response)
    }
    @discardableResult
    func deleteProbe(_ path: String, response: DAVResponse) async throws -> Bool {
        if response.status == 404 { return true }
        guard response.status == 200 else { throw SyncFailure.http(response.status) }
        let marker = try SyncCodec.decode(SyncProbeMarker.self, response.data)
        guard marker.kind == "pindo-probe-v3", ["a", "b", "c"].contains(where: {
            path == "_work/" + marker.owner.uuidString.lowercased() + ".probe-" + $0 + ".json"
        }) else { throw SyncFailure.invalidData }
        // Pure capability probes contain no business input, even if another probe replaces them.
        return try await deleteDisposable(path, response: response)
    }
    private func deleteDisposable(_ path: String, response: DAVResponse) async throws -> Bool {
        let current = try await get(path)
        if current.status == 404 { return true }
        guard current.status == 200 else { throw SyncFailure.http(current.status) }
        guard current.data == response.data else { return false }
        do {
            let headers = DAVProbe.usableTag(current.etag).map { ["If-Match": $0] } ?? [:]
            let removed = try await request("DELETE", path: path, body: nil, headers: headers)
            if [409, 412].contains(removed.status) { return false }
            guard [200, 204, 404].contains(removed.status) else { throw SyncFailure.http(removed.status) }
        } catch {
            if let check = try? await get(path), check.status == 404 { return true }
            throw error
        }
        let check = try await get(path)
        if check.status == 404 { return true }
        guard check.status == 200 else { throw SyncFailure.http(check.status) }
        if check.data != response.data { return false }
        throw SyncFailure.configuration("工作文件删除尚未确认，将保留待清理状态并自动重试。")
    }

}

struct SyncProbeMarker: Codable, Sendable {
    var kind = "pindo-probe-v3"
    let owner: UUID
    let nonce: UUID
    let phase: String
    let createdAt: Date
}

/// Checks actual version semantics with two real, successive tags, not a fabricated tag format.
enum DAVProbe {
    static func usableTag(_ tag: String?) -> String? {
        guard let tag, !tag.trimmingCharacters(in: .whitespaces).isEmpty,
              tag.trimmingCharacters(in: .whitespaces) != "*", !tag.hasPrefix("W/"),
              tag.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return tag // Nutstore may return an unquoted tag; preserve it exactly in If-Match.
    }
    private static func failure(_ stage: String, _ detail: String, _ status: Int? = nil) -> SyncFailure {
        .serverCapability(stage: stage, detail: detail, status: status)
    }
    static func verify(_ dav: any DAVTransport, prefix supplied: String? = nil, owner: UUID = UUID()) async throws -> DAVCreationMode {
        let prefix = supplied ?? "_work/" + owner.uuidString.lowercased() + ".probe"
        let path = prefix + "-a.json", source = prefix + "-b.json", target = prefix + "-c.json"
        let nonce = UUID(), now = Date.now
        let a = try SyncCodec.encode(SyncProbeMarker(owner: owner, nonce: nonce, phase: "a", createdAt: now))
        let b = try SyncCodec.encode(SyncProbeMarker(owner: owner, nonce: nonce, phase: "b", createdAt: now))
        let c = try SyncCodec.encode(SyncProbeMarker(owner: owner, nonce: nonce, phase: "c", createdAt: now))
        do {
            let first = try await dav.request("PUT", path: path, body: a, headers: [:])
            guard [200, 201, 204].contains(first.status) else { throw SyncFailure.http(first.status) }
            let original = try await dav.get(path)
            guard original.status == 200, original.data == a else { throw failure("读回验证", "临时探测文件的内容与上传内容不一致。", original.status) }
            guard let oldTag = usableTag(original.etag) else { throw failure("读取 ETag", "服务器没有返回可用于版本校验的 ETag，或只返回弱 ETag。") }
            let update = try await dav.request("PUT", path: path, body: b, headers: ["If-Match": oldTag])
            guard [200, 201, 204].contains(update.status) else { throw failure("匹配版本写入", "服务器拒绝使用自己返回的 ETag 更新文件。", update.status) }
            let current = try await dav.get(path)
            guard current.status == 200, current.data == b, let newTag = usableTag(current.etag), newTag != oldTag else {
                throw failure("版本更新验证", "内容更新后缺少有效的新 ETag，或读回内容不一致。", current.status)
            }
            let stale = try await dav.request("PUT", path: path, body: c, headers: ["If-Match": oldTag])
            let protected = try await dav.get(path)
            guard [409, 412].contains(stale.status), protected.status == 200, protected.data == b else {
                throw failure("拒绝旧版本写入", "服务器未阻止过期版本覆盖新内容，不能安全同步。", stale.status)
            }
            let collision = try await dav.request("PUT", path: path, body: a, headers: ["If-None-Match": "*"])
            let after = try await dav.get(path)
            let mode: DAVCreationMode
            if collision.status == 412 && after.status == 200 && after.data == b {
                mode = .conditionalPut
            } else {
                guard [200, 201, 204, 400, 403, 405, 409, 412, 501].contains(collision.status) else { throw SyncFailure.http(collision.status) }
                // Some providers ignore If-None-Match. Validate exclusive MOVE instead; never fail open.
                let upload = try await dav.request("PUT", path: source, body: a, headers: [:])
                guard [200, 201, 204].contains(upload.status) else { throw SyncFailure.http(upload.status) }
                let moved = try await dav.moveExclusive(source, to: target)
                let targetRead = try await dav.get(target), sourceRead = try await dav.get(source)
                guard [201, 204].contains(moved.status), targetRead.status == 200, targetRead.data == a, sourceRead.status == 404 else {
                    throw failure("MOVE 创建验证", "If-None-Match 不受支持，替代的无覆盖 MOVE 创建也未通过验证。", moved.status)
                }
                let again = try await dav.request("PUT", path: source, body: c, headers: [:])
                guard [200, 201, 204].contains(again.status) else { throw SyncFailure.http(again.status) }
                let refused = try await dav.moveExclusive(source, to: target)
                let kept = try await dav.get(target), remaining = try await dav.get(source)
                guard [403, 409, 412].contains(refused.status), kept.status == 200, kept.data == a,
                      remaining.status == 200, remaining.data == c else {
                    throw failure("MOVE 禁止覆盖验证", "服务器没有保护已存在的目标文件，已停止同步。", refused.status)
                }
                mode = .exclusiveMove
            }
            try await cleanupConfirmed(dav, paths: [path, source, target], known: [a, b, c])
            return mode
        } catch {
            await cleanup(dav, paths: [path, source, target], known: [a, b, c])
            throw error
        }
    }
    static func conditionalCreate(_ dav: any DAVTransport, path: String, data: Data) async throws {
        let response = try await dav.request("PUT", path: path, body: data, headers: ["If-None-Match": "*"])
        guard [200, 201, 204, 412].contains(response.status) else { throw SyncFailure.http(response.status) }
        let verified = try await dav.get(path)
        guard verified.status == 200, verified.data == data else { throw SyncFailure.identityCollision }
    }
    static func moveCreate(_ dav: any DAVTransport, path: String, data: Data, staging supplied: String? = nil) async throws {
        let staging = supplied ?? SyncWorkFile(owner: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)), data: data, kind: .payload).path
        guard let work = SyncWorkFile(path: staging), work.kind == .payload else { throw SyncFailure.invalidData }
        try work.validate(data)
        let existing = try await dav.get(path)
        if existing.status == 200 {
            try await cleanupConfirmed(dav, paths: [staging], known: [data])
            guard existing.data == data else { throw SyncFailure.identityCollision }
            return
        }
        guard existing.status == 404 else { throw SyncFailure.http(existing.status) }
        do {
            let upload = try await dav.request("PUT", path: staging, body: data, headers: [:])
            guard [200, 201, 204].contains(upload.status) else { throw SyncFailure.http(upload.status) }
            let check = try await dav.get(staging)
            guard check.status == 200, check.data == data else { throw SyncFailure.invalidData }
            let moved = try await dav.moveExclusive(staging, to: path)
            guard [201, 204, 403, 404, 409, 412].contains(moved.status) else { throw SyncFailure.http(moved.status) }
            let final = try await dav.get(path)
            guard final.status == 200 else { throw SyncFailure.http(moved.status == 201 ? final.status : moved.status) }
            guard final.data == data else { throw SyncFailure.identityCollision }
            try await cleanupConfirmed(dav, paths: [staging], known: [data])
        } catch {
            // MOVE may have committed before its response was lost.
            let final = try? await dav.get(path)
            await cleanup(dav, paths: [staging], known: [data])
            if final?.status == 200 && final?.data == data { try await cleanupConfirmed(dav, paths: [staging], known: [data]); return }
            throw error
        }
    }
    private static func cleanupConfirmed(_ dav: any DAVTransport, paths: [String], known: [Data]) async throws {
        for path in paths {
            let current = try await dav.get(path)
            if current.status == 404 { continue }
            guard current.status == 200 else { throw SyncFailure.http(current.status) }
            if known.contains(current.data) {
                let removed: Bool
                if SyncWorkFile(path: path) != nil { removed = try await dav.deleteWorkFile(path, response: current) }
                else { removed = try await dav.deleteProbe(path, response: current) }
                guard removed else { throw SyncFailure.configuration("工作文件已变化，保留新内容并稍后重试清理。") }
            }
        }
    }
    private static func cleanup(_ dav: any DAVTransport, paths: [String], known: [Data]) async {
        for path in paths {
            if let response = try? await dav.get(path), response.status == 200, known.contains(response.data) {
                if SyncWorkFile(path: path) != nil { _ = try? await dav.deleteWorkFile(path, response: response) }
                else { _ = try? await dav.deleteProbe(path, response: response) }
            }
        }
    }
}
