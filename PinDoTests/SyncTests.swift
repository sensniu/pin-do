import XCTest

/// Real URLSession/WebDAVClient requests, intercepted in process; never contacts a network host.
final class BootstrapDAVProtocol: URLProtocol, @unchecked Sendable {
    static let server = BootstrapDAVServer()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bootstrap.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let result = try Self.server.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: result.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class BootstrapDAVServer: @unchecked Sendable {
    private let lock = NSLock()
    private var directories: Set<String> = ["/dav"]
    private var files: [String: Data] = [:]
    private var denied = false
    private var puts = 0
    private var ignoreCreateCondition = false, ignoreMatch = false, ignoreMoveGuard = false, missingTag = false
    private var bareTag = false
    private var failMovedDestination: String?
    private var competingMove: (path: String, data: Data)?
    func reset(denied: Bool = false, nutstore: Bool = false, unsafeMatch: Bool = false, unsafeMove: Bool = false, missingTag: Bool = false) {
        lock.withLock {
            directories = ["/dav"]; files = [:]; self.denied = denied; puts = 0
            ignoreCreateCondition = nutstore; bareTag = nutstore; ignoreMatch = unsafeMatch
            ignoreMoveGuard = unsafeMove; self.missingTag = missingTag; failMovedDestination = nil; competingMove = nil
        }
    }
    func failMoveOnce(to path: String) { lock.withLock { failMovedDestination = path } }
    func insertCompetitorOnMove(path: String, data: Data) { lock.withLock { competingMove = (path, data) } }
    var filePaths: [String] { lock.withLock { files.keys.sorted() } }
    func remove(_ path: String) { lock.withLock { files.removeValue(forKey: path) } }
    func insertFile(_ path: String) { lock.withLock { files[path] = Data("occupied".utf8) } }
    var putCount: Int { lock.withLock { puts } }
    func respond(_ request: URLRequest) throws -> (status: Int, data: Data, headers: [String: String]) {
        try lock.withLock {
            let path = "/" + request.url!.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let method = request.httpMethod ?? "GET"
            func tag(_ data: Data) -> String { bareTag ? SyncCodec.hash(data) : "\"" + SyncCodec.hash(data) + "\"" }
            func result(_ status: Int, _ data: Data = Data()) -> (Int, Data, [String: String]) {
                (status, data, missingTag ? [:] : ["ETag": tag(data)])
            }
            if denied { return result(401) }
            if ["MKCOL", "PROPFIND"].contains(method), !request.url!.absoluteString.hasSuffix("/") { return result(301) }
            if method == "MKCOL" {
                if directories.contains(path) || files[path] != nil { return result(405) }
                guard directories.contains((path as NSString).deletingLastPathComponent) else { return result(409) }
                directories.insert(path); return result(201)
            }
            if method == "PROPFIND" {
                guard directories.contains(path) || files[path] != nil else { return result(404) }
                let descendants = request.value(forHTTPHeaderField: "Depth") == "0" ? [] : Array(directories.union(files.keys)).filter { ($0 as NSString).deletingLastPathComponent == path }
                let entries = ([path] + descendants).sorted().map { entry in
                    let collection = directories.contains(entry) ? "<d:collection/>" : ""
                    return "<d:response><d:href>\(entry)</d:href><d:propstat><d:prop><d:resourcetype>\(collection)</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
                }.joined()
                return result(207, Data(("<d:multistatus xmlns:d=\"DAV:\">" + entries + "</d:multistatus>").utf8))
            }
            let old = files[path]
            if method == "GET" { return result(old == nil ? 404 : 200, old ?? Data()) }
            if !ignoreCreateCondition, request.value(forHTTPHeaderField: "If-None-Match") == "*", old != nil { return result(412) }
            if !ignoreMatch, let expected = request.value(forHTTPHeaderField: "If-Match"), expected != old.map(tag) { return result(412) }
            if method == "MOVE" {
                guard let destination = request.value(forHTTPHeaderField: "Destination").flatMap(URL.init(string:)), destination.host == request.url!.host else { return result(400) }
                let target = "/" + destination.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let bytes = old else { return result(404) }
                guard directories.contains((target as NSString).deletingLastPathComponent) else { return result(409) }
                if let competingMove, competingMove.path == target { files[target] = competingMove.data; self.competingMove = nil }
                if files[target] != nil && request.value(forHTTPHeaderField: "Overwrite") == "F" && !ignoreMoveGuard { return result(409) }
                let existed = files[target] != nil
                files[target] = bytes; files.removeValue(forKey: path)
                if failMovedDestination == target { failMovedDestination = nil; throw URLError(.timedOut) }
                return result(existed ? 204 : 201)
            }
            if method == "PUT" {
                guard directories.contains((path as NSString).deletingLastPathComponent) else { return result(409) }
                // URLSession may turn the upload body into a stream for a URLProtocol.
                var body = request.httpBody
                if body == nil, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
                    body = bytes
                }
                files[path] = body ?? Data(); puts += 1; return result(old == nil ? 201 : 204)
            }
            if method == "DELETE" { files.removeValue(forKey: path); return result(204) }
            return result(405)
        }
    }
}

actor MemoryDAV: DAVTransport {
    var files: [String: Data] = [:]
    var directories: Set<String> = [""]
    var failAfterPUT: String?
    var ignoresConditions = false
    func setFailure(_ path: String) { failAfterPUT = path }
    func setUnsafe() { ignoresConditions = true }
    func overwrite(_ path: String, _ data: Data) { files[path] = data }
    func request(_ method: String, path: String, body: Data?, headers: [String: String]) async throws -> DAVResponse {
        let old = files[path]
        let tag = old.map { "\"" + SyncCodec.hash($0) + "\"" }
        if method == "GET" { return DAVResponse(data: old ?? Data(), status: old == nil ? 404 : 200, etag: tag) }
        if method == "PROPFIND", directories.contains(path) {
            let xml = "<d:multistatus xmlns:d=\"DAV:\"><d:response><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"
            return DAVResponse(data: Data(xml.utf8), status: 207, etag: nil)
        }
        if method == "MKCOL" { return DAVResponse(data: Data(), status: directories.insert(path).inserted ? 201 : 405, etag: nil) }
        if !ignoresConditions {
            if headers["If-None-Match"] == "*", old != nil { return DAVResponse(data: Data(), status: 412, etag: tag) }
            if let expected = headers["If-Match"], tag != expected { return DAVResponse(data: Data(), status: 412, etag: tag) }
        }
        if method == "PUT", let body {
            files[path] = body
            if failAfterPUT == path { failAfterPUT = nil; throw URLError(.timedOut) }
            return DAVResponse(data: Data(), status: old == nil ? 201 : 204, etag: "\"" + SyncCodec.hash(body) + "\"")
        }
        if method == "DELETE" { files.removeValue(forKey: path); return DAVResponse(data: Data(), status: 204, etag: nil) }
        throw SyncFailure.http(500)
    }
    func children(_ path: String) async throws -> [String] {
        let prefix = path.isEmpty ? "" : path + "/"
        return Set((Array(files.keys) + Array(directories)).filter { $0.hasPrefix(prefix) && $0 != path }
            .compactMap { $0.dropFirst(prefix.count).split(separator: "/").first.map(String.init) }).sorted()
    }
}

final class SyncTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func bootstrapClient(directory: String = "PinDo/nested", mode: DAVCreationMode? = nil) throws -> WebDAVClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BootstrapDAVProtocol.self]
        return try WebDAVClient(connection: SyncConnection(server: "https://bootstrap.invalid/dav/", directory: directory, username: "test-only"), password: "not-a-real-password", configuration: configuration, creationMode: mode)
    }
    func testNutstoreStyleConditionsUseExclusiveMoveAndPreserveRawTags() async throws {
        BootstrapDAVProtocol.server.reset(nutstore: true)
        let client = try bootstrapClient(); try await client.prepareRootHierarchy()
        let mode = try await client.probe()
        XCTAssertEqual(mode, .exclusiveMove)
        XCTAssertTrue(BootstrapDAVProtocol.server.filePaths.isEmpty)
        let first = try SyncCodec.encode("内容一"), second = try SyncCodec.encode("内容二")
        try await client.create("protected.json", data: first)
        do { try await client.create("protected.json", data: second); XCTFail("Existing bytes overwritten") }
        catch { guard case SyncFailure.identityCollision = error else { return XCTFail("Unexpected: \(error)") } }
        let saved = try await client.get("protected.json")
        XCTAssertEqual(saved.data, first)
        let tag = try XCTUnwrap(saved.etag)
        XCTAssertFalse(tag.hasPrefix("\""))
        let update = try await client.request("PUT", path: "protected.json", body: second, headers: ["If-Match": tag])
        XCTAssertEqual(update.status, 204)
        let stale = try await client.request("PUT", path: "protected.json", body: first, headers: ["If-Match": tag])
        XCTAssertEqual(stale.status, 412)
        XCTAssertEqual(BootstrapDAVProtocol.server.filePaths, ["/dav/PinDo/nested/protected.json"])
    }
    func testExclusiveMoveAllowsOnlyOneConcurrentCreator() async throws {
        BootstrapDAVProtocol.server.reset(nutstore: true)
        let a = try bootstrapClient(mode: .exclusiveMove), b = try bootstrapClient(mode: .exclusiveMove)
        try await a.prepareRootHierarchy()
        let first = try SyncCodec.encode("A"), second = try SyncCodec.encode("B")
        let wins = await withTaskGroup(of: Bool.self) { group in
            group.addTask { do { try await a.create("race.json", data: first); return true } catch { return false } }
            group.addTask { do { try await b.create("race.json", data: second); return true } catch { return false } }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        XCTAssertEqual(wins, 1)
        let final = try await a.get("race.json")
        XCTAssertTrue([first, second].contains(final.data))
        XCTAssertEqual(BootstrapDAVProtocol.server.filePaths, ["/dav/PinDo/nested/race.json"])
    }
    func testExclusiveMoveRecoversCommittedButLostResponseAndCleansStaging() async throws {
        BootstrapDAVProtocol.server.reset(nutstore: true)
        let client = try bootstrapClient(); try await client.prepareRootHierarchy(); try await client.probe()
        let bytes = try SyncCodec.encode("已提交但响应丢失")
        BootstrapDAVProtocol.server.failMoveOnce(to: "/dav/PinDo/nested/retry.json")
        try await client.create("retry.json", data: bytes)
        let count = BootstrapDAVProtocol.server.putCount
        try await client.create("retry.json", data: bytes)
        XCTAssertEqual(BootstrapDAVProtocol.server.putCount, count)
        XCTAssertEqual(BootstrapDAVProtocol.server.filePaths, ["/dav/PinDo/nested/retry.json"])
    }
    @MainActor
    func testConcurrentLibraryCreationAdoptsWinnerWithoutOverwrite() async throws {
        BootstrapDAVProtocol.server.reset(nutstore: true)
        let client = try bootstrapClient(); try await client.prepareRootHierarchy(); try await client.probe()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-library-race-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.8.1")
        let item = TodoItem(title: "创建竞争时保留本机事项", createdAt: now)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        try store.initializeSync()
        let winner = SyncLibrary(id: UUID()), bytes = try SyncCodec.wrap(winner)
        BootstrapDAVProtocol.server.insertCompetitorOnMove(path: "/dav/PinDo/nested/library.json", data: bytes)
        let sync = SyncCoordinator(); sync.attach(store)
        _ = try await sync.exchange(using: client)
        XCTAssertEqual(try store.syncState()?.libraryID, winner.id)
        let final = try await client.get("library.json")
        XCTAssertEqual(final.data, bytes)
        XCTAssertEqual(try store.storedItem(item.id)?.title, item.title)
        XCTAssertEqual(try store.syncState()?.pendingCount, 0)
        XCTAssertFalse(BootstrapDAVProtocol.server.filePaths.contains { $0.contains("pindo-upload-") })
    }
    @MainActor
    func testNutstoreStyleTwoClientsExchangeAndUpdateExistingHeads() async throws {
        BootstrapDAVProtocol.server.reset(nutstore: true)
        let client = try bootstrapClient(); try await client.prepareRootHierarchy()
        let mode = try await client.probe()
        let secondClient = try bootstrapClient(mode: mode)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-nutstore-mode-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try TodoRepository(paths: AppPaths(root: root.appendingPathComponent("a")), appVersion: "0.8.1")
        let b = try TodoRepository(paths: AppPaths(root: root.appendingPathComponent("b")), appVersion: "0.8.1")
        let item = TodoItem(title: "初始", notes: "原备注", createdAt: now)
        try a.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        try a.initializeSync(); try b.initializeSync()
        var state = try XCTUnwrap(a.syncState()); state.remoteCreationMode = mode; try a.saveSyncState(state)
        let ca = SyncCoordinator(), cb = SyncCoordinator(); ca.attach(a); cb.attach(b)
        _ = try await ca.exchange(using: client); _ = try await cb.exchange(using: secondClient)
        var ai = try XCTUnwrap(a.storedItem(item.id)), bi = try XCTUnwrap(b.storedItem(item.id))
        ai.title = "Mac 改标题"; bi.notes = "另一端改备注"
        try a.commit(ai, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: now), clearDraft: true)
        try b.commit(bi, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: now), clearDraft: true)
        _ = try await cb.exchange(using: secondClient); _ = try await ca.exchange(using: client); _ = try await cb.exchange(using: secondClient)
        XCTAssertEqual(try a.loadActiveItems(), try b.loadActiveItems())
        XCTAssertEqual(try a.storedItem(item.id)?.title, ai.title)
        XCTAssertEqual(try a.storedItem(item.id)?.notes, bi.notes)
        XCTAssertEqual(try a.syncState()?.remoteCreationMode, .exclusiveMove)
        XCTAssertGreaterThan(try a.syncState()!.outgoing.sequence, 1)
        XCTAssertFalse(BootstrapDAVProtocol.server.filePaths.contains { $0.contains("pindo-upload-") || $0.contains("probe-") })
        _ = try BackupCodec.decode(BackupCodec.encode(a.archive()))
    }
    func testBrokenVersionChecksAndBrokenMoveAreStillRejectedWithDetails() async throws {
        for variant in 0..<3 {
            BootstrapDAVProtocol.server.reset(nutstore: true, unsafeMatch: variant == 0, unsafeMove: variant == 1, missingTag: variant == 2)
            let client = try bootstrapClient(); try await client.prepareRootHierarchy()
            do { try await client.probe(); XCTFail("Unsafe provider accepted") }
            catch {
                guard case SyncFailure.serverCapability(let stage, _, _) = error else { return XCTFail("No diagnostic: \(error)") }
                XCTAssertTrue(stage.contains(["旧版本", "禁止覆盖", "ETag"][variant]))
            }
            XCTAssertTrue(BootstrapDAVProtocol.server.filePaths.isEmpty)
        }
    }
    func testOldSyncStateLoadsWithoutCreationCapabilityAndNewStatePersistsIt() throws {
        var state = SyncState(); state.remoteCreationMode = .exclusiveMove
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(SyncState.self, from: data).remoteCreationMode, .exclusiveMove)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "remoteCreationMode")
        XCTAssertNil(try JSONDecoder().decode(SyncState.self, from: JSONSerialization.data(withJSONObject: old)).remoteCreationMode)
    }
    @MainActor
    func testInterruptedInitialLibraryPublishReusesPersistedProposal() async throws {
        BootstrapDAVProtocol.server.reset(nutstore: true)
        let client = try bootstrapClient(); try await client.prepareRootHierarchy(); try await client.probe()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-initial-proposal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.8.1")
        try store.initializeSync()
        let proposed = UUID()
        var state = try XCTUnwrap(store.syncState()); state.proposedLibraryID = proposed
        try store.saveSyncState(state)
        let sync = SyncCoordinator(); sync.attach(store)
        _ = try await sync.exchange(using: client)
        XCTAssertEqual(try store.syncState()?.libraryID, proposed)
        XCTAssertNil(try store.syncState()?.proposedLibraryID)
        let published = try await client.get("library.json")
        XCTAssertEqual(try SyncCodec.unwrap(SyncLibrary.self, published.data).id, proposed)
    }
    @MainActor
    func testFirstSyncCreatesNestedCollectionsAndAcceptsInitiallyMissingFiles() async throws {
        BootstrapDAVProtocol.server.reset()
        let client = try bootstrapClient()
        try await client.prepareRootHierarchy(); try await client.prepareRootHierarchy() // Existing folders are verified, not errors.
        try await client.probe()
        let missing = try await client.get("library.json")
        XCTAssertEqual(missing.status, 404)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-first-network-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.8.0")
        try store.initializeSync()
        let sync = SyncCoordinator(); sync.attach(store)
        _ = try await sync.exchange(using: client) // No todo, no head.json yet: valid initialized empty library.
        XCTAssertNotNil(try store.syncState()?.libraryID)
        XCTAssertNotNil(try store.syncState()?.lastSuccess)
        let item = TodoItem(title: "第一次新增后发送", createdAt: now)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        _ = try await sync.exchange(using: client)
        XCTAssertEqual(try store.syncState()?.pendingCount, 0)
        XCTAssertEqual(try store.syncState()?.outgoing.sequence, 1)
        let second = try TodoRepository(paths: AppPaths(root: root.appendingPathComponent("second")), appVersion: "0.8.0")
        try second.initializeSync()
        let joining = SyncCoordinator(); joining.attach(second)
        _ = try await joining.exchange(using: client)
        XCTAssertEqual(try second.loadActiveItems().first?.title, item.title)
    }
    @MainActor
    func testAlreadyBoundLibraryMissingDoesNotCreateReplacement() async throws {
        BootstrapDAVProtocol.server.reset()
        let client = try bootstrapClient(); try await client.prepareRootHierarchy()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-missing-library-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.8.0")
        let item = TodoItem(title: "不能被空库覆盖", createdAt: now)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        try store.initializeSync()
        let sync = SyncCoordinator(); sync.attach(store)
        _ = try await sync.exchange(using: client)
        let library = try store.syncState()?.libraryID, count = BootstrapDAVProtocol.server.putCount
        BootstrapDAVProtocol.server.remove("/dav/PinDo/nested/library.json")
        do { _ = try await sync.exchange(using: client); XCTFail("Lost library silently recreated") }
        catch { guard case SyncFailure.wrongLibrary = error else { return XCTFail("Unexpected: \(error)") } }
        XCTAssertEqual(BootstrapDAVProtocol.server.putCount, count)
        XCTAssertEqual(try store.syncState()?.libraryID, library)
        XCTAssertEqual(try store.storedItem(item.id)?.title, item.title)
    }
    func testFirstSyncAuthenticationErrorIsNotTreatedAsEmptyDirectory() async throws {
        BootstrapDAVProtocol.server.reset(denied: true)
        let client = try bootstrapClient()
        do { try await client.prepareRootHierarchy(); XCTFail("Authentication failure ignored") }
        catch { guard case SyncFailure.http(401) = error else { return XCTFail("Unexpected: \(error)") } }
        XCTAssertEqual(BootstrapDAVProtocol.server.putCount, 0)
    }
    func testFirstSyncRejectsFileOccupyingConfiguredFolder() async throws {
        BootstrapDAVProtocol.server.reset()
        BootstrapDAVProtocol.server.insertFile("/dav/PinDo")
        let client = try bootstrapClient()
        do { try await client.prepareRootHierarchy(); XCTFail("File accepted as directory") } catch {}
        XCTAssertEqual(BootstrapDAVProtocol.server.putCount, 0)
    }
    private func seed(_ items: [TodoItem], projects: [Project] = []) throws -> SyncState {
        var state = SyncState()
        if let change = try SyncBuilder.capture(before: SyncContents(items: [], projects: [], events: []), after: SyncContents(items: items, projects: projects, events: []), state: state) { state.changes = [change] }
        return state
    }
    private func edit(_ state: SyncState, original: TodoItem, updated: TodoItem) throws -> SyncChange {
        try XCTUnwrap(SyncBuilder.capture(before: SyncContents(items: [original], projects: [], events: []), after: SyncContents(items: [updated], projects: [], events: []), state: state))
    }
    func testIndependentFieldsConvergeUnderReorderingAndDuplicates() throws {
        let original = TodoItem(title: "标题", notes: "备注", createdAt: now), state = try seed([original])
        var a = original, b = original
        a.title = "Mac 标题"; b.notes = "Android 备注"
        let changes = try [edit(state, original: original, updated: a), edit(state, original: original, updated: b)]
        for received in [changes, changes.reversed(), changes + changes] {
            let graph = try SyncGraph(state.changes + received)
            let item = try XCTUnwrap(graph.projection().items.first)
            XCTAssertEqual(item.title, a.title); XCTAssertEqual(item.notes, b.notes)
            XCTAssertTrue(try graph.conflicts().isEmpty)
        }
    }
    func testThreeConcurrentValuesAndLateBranchSurviveResolution() throws {
        let original = TodoItem(title: "原始", createdAt: now), state = try seed([original])
        let branches = try ["一", "二", "三"].map { text -> SyncChange in var item = original; item.title = text; return try edit(state, original: original, updated: item) }
        let graph = try SyncGraph(state.changes + Array(branches.prefix(2)))
        let conflict = try XCTUnwrap(graph.conflicts().first)
        let resolution = SyncWrite(entity: conflict.entity, field: conflict.field, parents: conflict.candidates.map(\.id), value: conflict.candidates[0].value)
        let resolved = SyncChange(writerID: UUID(), date: now, writes: [resolution])
        let merged = try SyncGraph(state.changes + branches + [resolved])
        XCTAssertEqual(try merged.conflicts().first?.candidates.count, 2)
        XCTAssertEqual(merged.writes.count, state.changes.flatMap(\.writes).count + 4)
    }
    func testExplicitNullAndTextRemovalAreRealConflicts() throws {
        let original = TodoItem(title: "标题", notes: "正文", dueAt: now, createdAt: now), state = try seed([original])
        var a = original, b = original; a.notes = ""; a.dueAt = nil; b.notes = "新的正文"; b.dueAt = now.addingTimeInterval(60)
        let graph = try SyncGraph(state.changes + [edit(state, original: original, updated: a), edit(state, original: original, updated: b)])
        XCTAssertEqual(Set(try graph.conflicts().map(\.field)), ["notes", "deadline"])
    }
    func testCompletionAndEditingDoNotResurrectAndIndependentUndoIsScoped() throws {
        let original = TodoItem(title: "待办", createdAt: now), state = try seed([original])
        var done = original; done.status = .completed; done.completedAt = now
        let first = TodoEvent(itemID: original.id, kind: .completed, occurredAt: now)
        let second = TodoEvent(itemID: original.id, kind: .completed, occurredAt: now.addingTimeInterval(1))
        func completed(_ event: TodoEvent) throws -> SyncChange {
            try XCTUnwrap(SyncBuilder.capture(before: SyncContents(items: [original], projects: [], events: []), after: SyncContents(items: [done], projects: [], events: [event]), state: state))
        }
        let c1 = try completed(first), c2 = try completed(second)
        var local = state; local.changes.append(c1)
        let undo = TodoEvent(itemID: original.id, kind: .completionUndone, occurredAt: now.addingTimeInterval(2), relatedCompletionID: first.id)
        let u = try XCTUnwrap(SyncBuilder.capture(before: SyncContents(items: [done], projects: [], events: [first]), after: SyncContents(items: [original], projects: [], events: [first, undo]), state: local))
        var changed = original; changed.notes = "离线修改保留"
        let merged = try SyncGraph(state.changes + [u, c2, edit(state, original: original, updated: changed), c1])
        XCTAssertEqual(try merged.projection().items.first?.status, .completed)
        XCTAssertEqual(try merged.projection().items.first?.notes, changed.notes)
        XCTAssertTrue(try merged.conflicts().isEmpty)
    }
    func testCompleteVersusAbandonIsPreservedAsStatusConflict() throws {
        let original = TodoItem(title: "事项", createdAt: now), state = try seed([original])
        var a = original, b = original; a.status = .completed; a.completedAt = now; b.status = .abandoned; b.abandonedAt = now
        let graph = try SyncGraph(state.changes + [edit(state, original: original, updated: a), edit(state, original: original, updated: b)])
        XCTAssertEqual(try graph.projection().items.first?.status, .conflicted)
        XCTAssertEqual(try graph.conflicts().first?.field, "lifecycle")
    }
    func testArchiveRestoreDoesNotReclaimOldGeneration() throws {
        let project = Project(name: "项目", now: now)
        let item = TodoItem(title: "旧事项", projectID: project.id, createdAt: now)
        var state = try seed([item], projects: [project])
        var archived = project; archived.status = .archived; archived.archivedAt = now
        let archive = try XCTUnwrap(SyncBuilder.capture(before: SyncContents(items: [item], projects: [project], events: []), after: SyncContents(items: [item], projects: [archived], events: []), state: state))
        state.changes.append(archive)
        let restore = try XCTUnwrap(SyncBuilder.capture(before: SyncContents(items: [item], projects: [archived], events: []), after: SyncContents(items: [item], projects: [project], events: []), state: state))
        state.changes.append(restore)
        XCTAssertNil(try SyncGraph(state.changes).projection().items.first?.projectID)
        XCTAssertEqual(try SyncGraph(state.changes).projection().projects.first?.status, .active)
    }
    func testMissingParentsIdentityCollisionAndCyclesAreRejected() throws {
        let a = UUID(), b = UUID(), entity = SyncGraph.entity("todo", UUID())
        let wa = SyncWrite(id: a, entity: entity, field: "title", parents: [b], value: Data())
        let wb = SyncWrite(id: b, entity: entity, field: "title", parents: [a], value: Data())
        XCTAssertThrowsError(try SyncGraph([SyncChange(writerID: UUID(), date: now, writes: [wa])]))
        XCTAssertThrowsError(try SyncGraph([SyncChange(writerID: UUID(), date: now, writes: [wa, wb])]))
        let original = TodoItem(title: "a", createdAt: now), state = try seed([original])
        var collision = state.changes[0]; collision.writes = []
        XCTAssertThrowsError(try SyncGraph(state.changes + [collision]))
    }
    func testWireChecksumAndUTCDateRoundTrip() throws {
        let value = TodoItem(title: "中文 👩🏽‍💻", notes: "第一行\n第二行", dueAt: now, createdAt: now)
        let data = try SyncCodec.wrap(value)
        XCTAssertEqual(try SyncCodec.unwrap(TodoItem.self, data), value)
        XCTAssertTrue(String(data: try SyncCodec.encode(value), encoding: .utf8)!.contains("Z"))
        var corrupt = data; corrupt[corrupt.count / 2] ^= 1
        XCTAssertThrowsError(try SyncCodec.unwrap(TodoItem.self, corrupt))
    }
    func testRequiredDirectoryAndDAVListingContainment() throws {
        XCTAssertThrowsError(try SyncConnection(server: "https://dav.example/dav/", directory: "", username: "user").root)
        XCTAssertThrowsError(try SyncConnection(server: "https://dav.example/dav/", directory: "../other", username: "user").root)
        XCTAssertThrowsError(try SyncConnection(server: "http://dav.example/", directory: "PinDo", username: "user").root)
        let root = try SyncConnection(server: "https://dav.example/dav/", directory: "我的待办/同步", username: "user").root
        XCTAssertTrue(root.path.hasSuffix("我的待办/同步"))
        let base = URL(string: "https://dav.example/dav/PinDo/writers/")!
        let xml = "<d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>/dav/PinDo/writers/abc/</d:href></d:response></d:multistatus>"
        XCTAssertEqual(try DAVListing.parse(Data(xml.utf8), directory: base), ["abc"])
        XCTAssertThrowsError(try DAVListing.parse(Data(xml.replacingOccurrences(of: "/dav/PinDo/writers/abc/", with: "/private/other/").utf8), directory: base))
        let truncated = "<d:multistatus xmlns:d=\"DAV:\">" + String(repeating: "<d:response><d:href>/dav/PinDo/writers/</d:href></d:response>", count: 750) + "</d:multistatus>"
        XCTAssertThrowsError(try DAVListing.parse(Data(truncated.utf8), directory: base))
    }
    func testConditionalWriteProbeRejectsUnsafeServer() async throws {
        let safe = MemoryDAV(); try await safe.probe()
        let unsafe = MemoryDAV(); await unsafe.setUnsafe()
        do { try await unsafe.probe(); XCTFail("Unsafe DAV accepted") } catch {}
    }
    @MainActor
    func testTwoRepositoriesExchangeOfflineEditsAndPersistOutbox() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try TodoRepository(paths: AppPaths(root: root.appendingPathComponent("a")), appVersion: "0.6.0")
        let b = try TodoRepository(paths: AppPaths(root: root.appendingPathComponent("b")), appVersion: "0.6.0")
        let item = TodoItem(title: "起点", notes: "初始备注", createdAt: now)
        try a.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        try a.initializeSync(); try b.initializeSync()
        let ca = SyncCoordinator(), cb = SyncCoordinator(); ca.attach(a); cb.attach(b)
        let dav = MemoryDAV()
        _ = try await ca.exchange(using: dav); _ = try await cb.exchange(using: dav)
        XCTAssertEqual(try b.loadActiveItems().first?.id, item.id)
        var ai = try XCTUnwrap(a.loadActiveItems().first), bi = try XCTUnwrap(b.loadActiveItems().first)
        ai.title = "Mac 修改"; bi.notes = "Android 修改"
        try a.commit(ai, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: now), clearDraft: true)
        try b.commit(bi, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: now), clearDraft: true)
        XCTAssertEqual(try a.syncState()?.pendingCount, 1)
        _ = try await cb.exchange(using: dav); _ = try await ca.exchange(using: dav); _ = try await cb.exchange(using: dav)
        XCTAssertEqual(try a.loadActiveItems(), try b.loadActiveItems())
        XCTAssertEqual(try a.loadActiveItems().first?.title, "Mac 修改")
        XCTAssertEqual(try a.loadActiveItems().first?.notes, "Android 修改")
        XCTAssertEqual(try a.archive().formatVersion, 3)
        _ = try BackupCodec.decode(BackupCodec.encode(a.archive()))
        try a.restore(a.archive())
        XCTAssertEqual(try a.loadActiveItems().first?.title, "Mac 修改")
    }
    @MainActor
    func testSyncRefreshKeepsManualLayoutsAndOnlyPlacesNewCardsWithoutUploadEcho() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-sync-layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try TodoRepository(paths: AppPaths(root: root.appendingPathComponent("a")), appVersion: "0.6.0")
        let b = try TodoRepository(paths: AppPaths(root: root.appendingPathComponent("b")), appVersion: "0.6.0")
        let project = try a.createProject(name: "项目")
        let item = TodoItem(title: "已有事项", projectID: project.id, createdAt: now)
        try a.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        try a.initializeSync(); try b.initializeSync()
        let ca = SyncCoordinator(), cb = SyncCoordinator(), dav = MemoryDAV()
        ca.attach(a); cb.attach(b)
        _ = try await ca.exchange(using: dav); _ = try await cb.exchange(using: dav)
        let data = try a.loadBoardData()
        let board = BoardModel(items: data.items, projects: data.projects, persistence: a)
        ca.didReceive = { board.refreshFromSync() }
        board.moveNote(item.id, to: CGPoint(x: -320, y: 180))
        board.selectScope(.project(project.id)); board.moveNote(item.id, to: CGPoint(x: 240, y: -100))
        board.selectScope(.all)
        let original = board.layout.positions[item.id], camera = board.viewportBounds
        let count = try a.syncState()!.changes.count
        board.bringToFront(item.id); board.moveNote(item.id, to: original!)
        XCTAssertEqual(try a.syncState()!.changes.count, count)
        XCTAssertEqual(try a.syncState()!.pendingCount, 0)
        var remote = try XCTUnwrap(b.storedItem(item.id)); remote.notes = "远端修改\n完整保留\n第三行"
        try b.commit(remote, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: now), clearDraft: true)
        let newItem = TodoItem(title: "远端新增", dueAt: now.addingTimeInterval(60), projectID: project.id, createdAt: now)
        try b.commit(newItem, event: TodoEvent(itemID: newItem.id, kind: .created, occurredAt: now), clearDraft: true)
        _ = try await cb.exchange(using: dav); _ = try await ca.exchange(using: dav)
        XCTAssertEqual(board.layout.positions[item.id], original)
        XCTAssertEqual(board.viewportBounds, camera)
        XCTAssertEqual(board.items.first { $0.id == item.id }?.notes, remote.notes)
        XCTAssertFalse(BoardLayoutEngine.conflicts(board.layout.frame(for: item.id)!, board.layout.frame(for: newItem.id)!))
        XCTAssertEqual(try a.syncState()!.pendingCount, 0)
        board.selectScope(.project(project.id))
        XCTAssertEqual(board.layout.positions[item.id], CGPoint(x: 240, y: -100))
        XCTAssertNotNil(board.layout.positions[newItem.id])
        XCTAssertEqual(try a.loadActiveItems(), try b.loadActiveItems())
        _ = try BackupCodec.decode(BackupCodec.encode(a.archive()))
    }

    @MainActor
    func testLostUploadResponseRetriesSamePacketWithoutDuplicatingEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-sync-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.6.0")
        let item = TodoItem(title: "重试保留", createdAt: now)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        try store.initializeSync()
        let coordinator = SyncCoordinator(); coordinator.attach(store)
        let dav = MemoryDAV(), writer = try XCTUnwrap(store.syncState()).writerID.uuidString.lowercased()
        await dav.setFailure(SyncCoordinator.packetPath(writer: writer, sequence: 1))
        do { _ = try await coordinator.exchange(using: dav); XCTFail("Expected interrupted response") } catch {}
        let pending = try XCTUnwrap(store.syncState()?.pending)
        _ = try await coordinator.exchange(using: dav)
        XCTAssertNil(try store.syncState()?.pending)
        XCTAssertEqual(try store.syncState()?.outgoing.checksum, SyncCodec.hash(pending))
        XCTAssertEqual(try store.syncContents().events.count, 1)
        XCTAssertEqual(try store.syncState()?.pendingCount, 0)
    }
    @MainActor
    func testSyncInitializationSurvivesReopenAndRepairsManifestHandshake() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-sync-reopen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        var repository: TodoRepository? = try TodoRepository(paths: paths, appVersion: "0.6.0")
        let item = TodoItem(title: "持久化", createdAt: now)
        try repository!.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        try repository!.initializeSync()
        let writer = try repository!.syncState()!.writerID
        repository = nil
        var manifest = try JSONDecoder().decode(StoreManifest.self, from: Data(contentsOf: paths.manifest)); manifest.formatVersion = 2
        try JSONEncoder().encode(manifest).write(to: paths.manifest)
        repository = try TodoRepository(paths: paths, appVersion: "0.6.0")
        XCTAssertEqual(try repository!.syncState()?.writerID, writer)
        XCTAssertEqual(try repository!.syncState()?.pendingCount, 1)
        XCTAssertEqual(try repository!.loadActiveItems().first?.id, item.id)
        XCTAssertEqual(try JSONDecoder().decode(StoreManifest.self, from: Data(contentsOf: paths.manifest)).formatVersion, 3)
        repository = nil
    }
    @MainActor
    func testEditingOldDraftAfterRemoteCompletionPreservesInputAndEndedState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-draft-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.6.0")
        let original = TodoItem(title: "草稿", notes: "原始", createdAt: now)
        try store.commit(original, event: TodoEvent(itemID: original.id, kind: .created, occurredAt: now), clearDraft: true)
        try store.initializeSync()
        let current = try XCTUnwrap(store.storedItem(original.id))
        var draft = NoteDraft(item: current, now: now); draft.syncBaseline = try store.baseline(for: current); draft.notes = "编辑中不能丢失的内容"
        try store.saveDraft(draft)
        var completed = current; completed.status = .completed; completed.completedAt = now
        try store.commit(completed, event: TodoEvent(itemID: current.id, kind: .completed, occurredAt: now), clearDraft: false)
        XCTAssertEqual(try store.loadDraft()?.notes, draft.notes)
        var submitted = current; submitted.notes = draft.notes
        let result = try store.commitDraft(submitted, event: TodoEvent(itemID: current.id, kind: .edited, occurredAt: now), draft: draft)
        XCTAssertEqual(result.status, .completed); XCTAssertEqual(result.notes, draft.notes)
        _ = try BackupCodec.encode(store.archive())
    }
    @MainActor
    func testStaleDraftDoesNotOverwriteUneditedRemoteFields() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-baseline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.6.0")
        let p = try store.createProject(name: "P"), q = try store.createProject(name: "Q")
        let original = TodoItem(title: "原题", notes: "旧备注", dueAt: now, projectID: p.id, createdAt: now)
        try store.commit(original, event: TodoEvent(itemID: original.id, kind: .created, occurredAt: now), clearDraft: true)
        try store.initializeSync()
        var draft = NoteDraft(item: original, now: now); draft.syncBaseline = try store.baseline(for: original); draft.title = "本地标题"
        var remote = original; remote.notes = "远端新备注"; remote.projectID = q.id; remote.dueAt = now.addingTimeInterval(60)
        try store.commit(remote, event: TodoEvent(itemID: original.id, kind: .edited, occurredAt: now), clearDraft: true)
        let priorAssignments = try store.storedItem(original.id)!.projectAssignments
        var submitted = original; submitted.title = draft.title
        let event = TodoEvent(itemID: original.id, kind: .edited, occurredAt: now)
        let result = try store.commitDraft(submitted, event: event, draft: draft)
        XCTAssertEqual(result.title, draft.title); XCTAssertEqual(result.notes, remote.notes)
        XCTAssertEqual(result.projectID, q.id); XCTAssertEqual(result.dueAt, remote.dueAt)
        XCTAssertEqual(result.projectAssignments, priorAssignments)
        let recorded = try XCTUnwrap(store.syncContents().events.first { $0.id == event.id })
        XCTAssertEqual(recorded.previousDeadline, remote.dueAt); XCTAssertEqual(recorded.newDeadline, remote.dueAt)
    }
    @MainActor
    func testLegacyBackupMergePreservesNewItemsAndCurrentCompletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-restore-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.6.0")
        var item = TodoItem(title: "旧标题", createdAt: now)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        let old = try store.archive()
        try store.initializeSync()
        item.title = "新标题"
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: now), clearDraft: true)
        item.status = .completed; item.completedAt = now
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .completed, occurredAt: now), clearDraft: true)
        let extra = TodoItem(title: "备份以后新增", createdAt: now)
        try store.commit(extra, event: TodoEvent(itemID: extra.id, kind: .created, occurredAt: now), clearDraft: true)
        try store.restore(old)
        XCTAssertNotNil(try store.storedItem(extra.id))
        XCTAssertEqual(try store.storedItem(item.id)?.status, .completed)
        XCTAssertTrue(try SyncGraph(store.syncState()!.changes).conflicts().contains { $0.field == "title" })
        _ = try BackupCodec.encode(store.archive())
    }
    @MainActor
    func testConflictResolutionIsDurableAndRejectsUnseenBranch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-conflict-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.6.0")
        let item = TodoItem(title: "原题", createdAt: now)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        try store.initializeSync()
        let state = try XCTUnwrap(store.syncState())
        var a = item, b = item, c = item; a.title = "a"; b.title = "b"; c.title = "c"
        try store.acceptSync([edit(state, original: item, updated: a), edit(state, original: item, updated: b)], cursors: [:])
        let oldConflict = try XCTUnwrap(SyncGraph(store.syncState()!.changes).conflicts().first)
        try store.acceptSync([edit(state, original: item, updated: c)], cursors: [:])
        XCTAssertThrowsError(try store.resolveSyncConflict(oldConflict, candidate: oldConflict.candidates[0]))
        let current = try XCTUnwrap(SyncGraph(store.syncState()!.changes).conflicts().first)
        try store.resolveSyncConflict(current, candidate: current.candidates[0])
        XCTAssertTrue(try SyncGraph(store.syncState()!.changes).conflicts().isEmpty)
        XCTAssertGreaterThan(try store.syncState()!.outboxIDs.count, 1)
        XCTAssertEqual(try store.storedItem(item.id)?.title, try SyncCodec.decode(String.self, current.candidates[0].value))
    }
    func testArchiveAndManualMoveToAnotherProjectConverge() throws {
        let p = Project(name: "P", now: now), q = Project(name: "Q", now: now)
        let item = TodoItem(title: "移动", projectID: p.id, createdAt: now), state = try seed([item], projects: [p, q])
        var archived = p; archived.status = .archived; archived.archivedAt = now
        var automatic = item; automatic.projectID = nil
        automatic.projectAssignments.append(ProjectAssignment(previousProjectID: p.id, projectID: nil, changedAt: now, reason: .archived))
        let archive = try XCTUnwrap(SyncBuilder.capture(before: SyncContents(items: [item], projects: [p, q], events: []), after: SyncContents(items: [automatic], projects: [archived, q], events: []), state: state))
        var moved = item; moved.projectID = q.id
        let move = try edit(state, original: item, updated: moved)
        let graph = try SyncGraph(state.changes + [archive, move])
        XCTAssertEqual(try graph.projection().items.first?.projectID, q.id)
        XCTAssertTrue(try graph.conflicts().isEmpty)
    }
    @MainActor
    func testFailedLocalWriteDoesNotLeaveSyncChangeOrLosePreviousValue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-atomic-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.6.0")
        let item = TodoItem(title: "正确内容", createdAt: now)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        try store.initializeSync()
        let count = try store.syncState()!.changes.count
        var invalid = item; invalid.title = "不应出现"
        XCTAssertThrowsError(try store.commit(invalid, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: Date(timeIntervalSince1970: .nan)), clearDraft: true))
        XCTAssertEqual(try store.syncState()!.changes.count, count)
        XCTAssertEqual(try store.storedItem(item.id)?.title, item.title)
    }

    @MainActor
    func testBootstrapPreservesEndedItemsInArchivedAndDeletedProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-history-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.6.0")
        let project = try store.createProject(name: "已归档项目")
        var item = TodoItem(title: "保留完成历史", projectID: project.id, createdAt: now)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        item.status = .completed; item.completedAt = now
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .completed, occurredAt: now), clearDraft: true)
        _ = try store.archiveProject(id: project.id)
        try store.initializeSync()
        XCTAssertEqual(try store.storedItem(item.id)?.projectID, project.id)
        XCTAssertEqual(try store.storedItem(item.id)?.status, .completed)
        XCTAssertEqual(try store.storedItem(item.id)?.createdAt, item.createdAt)
        _ = try store.deleteProject(id: project.id, action: .transferToUnassigned)
        _ = try BackupCodec.decode(BackupCodec.encode(store.archive()))
    }

    func testIndependentProtocolFixtureIsReadable() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sync-v1-project.json")
        let packet = try SyncCodec.unwrap(SyncPacket.self, Data(contentsOf: file))
        XCTAssertEqual(packet.version, 1); XCTAssertEqual(packet.sequence, 1)
        let graph = try SyncGraph(packet.changes)
        XCTAssertEqual(try graph.projection().projects.first?.name, "跨平台示例项目")
        XCTAssertEqual(try graph.projection().projects.first?.colorValue, ProjectColor(red: 0.25, green: 0.5, blue: 0.75))
    }
    func testAllThreeBranchDeliveryOrdersConverge() throws {
        let item = TodoItem(title: "原始", createdAt: now), state = try seed([item])
        let branches = try ["a", "b", "c"].map { name -> SyncChange in var updated = item; updated.title = name; return try edit(state, original: item, updated: updated) }
        var expected: [UUID]?
        for order in [[0,1,2], [0,2,1], [1,0,2], [1,2,0], [2,0,1], [2,1,0]] {
            let graph = try SyncGraph(state.changes + order.map { branches[$0] } + [branches[0]])
            let ids = try XCTUnwrap(graph.conflicts().first).candidates.map(\.id)
            if let expected { XCTAssertEqual(ids, expected) } else { expected = ids }
            XCTAssertEqual(ids.count, 3)
        }
    }
    func testMissingProjectGenerationWaitsInsteadOfDetachingItem() throws {
        let p = Project(name: "项目", now: now), item = TodoItem(title: "未到的恢复", createdAt: now)
        let state = try seed([item], projects: [p])
        let entity = SyncGraph.entity("todo", item.id)
        let graph = try SyncGraph(state.changes)
        let write = SyncWrite(entity: entity, field: "membership", parents: graph.heads(entity, "membership").map(\.id), value: try SyncCodec.encode(SyncMembership(projectID: p.id, generation: UUID())))
        XCTAssertThrowsError(try SyncGraph(state.changes + [SyncChange(writerID: UUID(), date: now, writes: [write])])) { error in
            guard case SyncFailure.missingDependency = error else { return XCTFail("Expected missing dependency, got \(error)") }
        }
    }
    @MainActor
    func testLostHeadResponseRecoversAfterHeadAlreadyAdvanced() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-head-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.6.0")
        let item = TodoItem(title: "头部响应丢失", createdAt: now)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        try store.initializeSync()
        let sync = SyncCoordinator(); sync.attach(store)
        let dav = MemoryDAV(), writer = try XCTUnwrap(store.syncState()).writerID.uuidString.lowercased()
        await dav.setFailure("writers/" + writer + "/head.json")
        do { _ = try await sync.exchange(using: dav); XCTFail("Expected interrupted response") } catch {}
        XCTAssertNotNil(try store.syncState()?.pending)
        _ = try await sync.exchange(using: dav)
        XCTAssertNil(try store.syncState()?.pending)
        XCTAssertEqual(try store.syncState()?.outgoing.sequence, 1)
        XCTAssertEqual(try store.syncContents().events.count, 1)
    }
    @MainActor
    func testChangedRemoteLibraryDoesNotOverwriteLocalData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-library-change-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.6.0")
        let item = TodoItem(title: "不得被空云端覆盖", createdAt: now)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        try store.initializeSync()
        let sync = SyncCoordinator(); sync.attach(store)
        let dav = MemoryDAV()
        _ = try await sync.exchange(using: dav)
        let bound = try store.syncState()?.libraryID
        await dav.overwrite("library.json", try SyncCodec.wrap(SyncLibrary(id: UUID())))
        do { _ = try await sync.exchange(using: dav); XCTFail("Expected identity protection") } catch {}
        XCTAssertEqual(try store.syncState()?.libraryID, bound)
        XCTAssertEqual(try store.storedItem(item.id)?.title, item.title)
    }

    @MainActor
    func testProjectEditorUsesOriginalFieldVersionsAndProtectsConfirmationScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-project-baseline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.6.0")
        let project = try store.createProject(name: "原项目")
        try store.initializeSync()
        let baseline = try XCTUnwrap(store.projectBaseline(project))
        _ = try store.renameProject(id: project.id, name: "远端名称")
        _ = try store.saveProjectDraft(baseline, name: "本地名称", color: project.colorValue)
        XCTAssertTrue(try SyncGraph(store.syncState()!.changes).conflicts().contains { $0.field == "name" })
        let item = TodoItem(title: "确认之后新增", projectID: project.id, createdAt: now)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        XCTAssertThrowsError(try store.checkProjectScope(project.id, expected: []))
        XCTAssertEqual(try store.storedItem(item.id)?.status, .active)
    }
    @MainActor
    func testRestoringSyncBackupToAnotherStoreRotatesWriterAndPreservesCandidates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-new-restore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try TodoRepository(paths: AppPaths(root: root.appendingPathComponent("source")), appVersion: "0.6.0")
        let target = try TodoRepository(paths: AppPaths(root: root.appendingPathComponent("target")), appVersion: "0.6.0")
        let item = TodoItem(title: "备份中的事项", createdAt: now)
        try source.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        try source.initializeSync()
        try target.restore(source.archive())
        XCTAssertNotEqual(try source.syncState()?.writerID, try target.syncState()?.writerID)
        XCTAssertEqual(try target.syncState()?.enabled, false)
        XCTAssertEqual(try target.loadActiveItems().first?.title, item.title)
        XCTAssertEqual(try target.syncState()?.outgoing.sequence, 0)
        XCTAssertEqual(try target.syncState()?.pendingCount, 1)
        _ = try BackupCodec.decode(BackupCodec.encode(target.archive()))
    }

    @MainActor
    func testMissingPublishedHeadDoesNotReportSuccessOrRecreateHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-missing-head-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.6.0")
        let item = TodoItem(title: "本地内容保留", createdAt: now)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        try store.initializeSync()
        let sync = SyncCoordinator(); sync.attach(store)
        let dav = MemoryDAV()
        _ = try await sync.exchange(using: dav)
        let state = try XCTUnwrap(store.syncState())
        let headPath = "writers/" + state.writerID.uuidString.lowercased() + "/head.json"
        _ = try await dav.request("DELETE", path: headPath, body: nil, headers: [:])
        do { _ = try await sync.exchange(using: dav); XCTFail("Missing published head accepted") }
        catch { guard case SyncFailure.incompleteListing = error else { return XCTFail("Unexpected error: \(error)") } }
        XCTAssertEqual(try store.syncState()?.lastSuccess, state.lastSuccess)
        XCTAssertEqual(try store.storedItem(item.id)?.title, item.title)
        let response = try await dav.get(headPath)
        XCTAssertEqual(response.status, 404)
    }

    @MainActor
    func testIncompleteInboxIsNotShownAsSynced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-pending-inbox-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.6.0")
        try store.initializeSync()
        var state = try XCTUnwrap(store.syncState())
        state.enabled = true; state.lastSuccess = now
        try store.saveSyncState(state)
        let write = SyncWrite(entity: SyncGraph.entity("todo", UUID()), field: "notes", parents: [UUID()], value: try SyncCodec.encode("等待前序版本"))
        let change = SyncChange(writerID: UUID(), date: now, writes: [write])
        try store.stageReceived([change], writer: change.writerID.uuidString.lowercased(), cursor: SyncCursor(sequence: 1, checksum: "pending"))
        XCTAssertThrowsError(try store.applyReceived())
        let sync = SyncCoordinator(); sync.attach(store)
        XCTAssertEqual(sync.message, "等待补齐同步数据")
        XCTAssertEqual(try store.syncState()?.inbox.count, 1)
        XCTAssertTrue(try store.syncState()!.cursors.isEmpty)
    }

    @MainActor
    func testBackupRejectsMaterializedContentThatDisagreesWithVersionGraph() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-snapshot-check-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.6.0")
        var item = TodoItem(title: "一致快照", createdAt: now)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        try store.initializeSync()
        let archive = try store.archive()
        item.title = "混入另一个时间点的内容"
        let records = try archive.records.map { record in
            record.bucket == "todo-active" ? StoredValue(key: record.key, bucket: record.bucket, payload: try JSONEncoder().encode(item)) : record
        }
        let inconsistent = StoreArchive(formatVersion: 3, appVersion: "0.6.0", createdAt: now, records: records)
        XCTAssertThrowsError(try BackupCodec.encode(inconsistent))
        XCTAssertNoThrow(try BackupCodec.encode(archive))
    }

    func testAssignmentIdentityCollisionDoesNotSilentlyDiscardHistory() throws {
        let item = TodoItem(title: "归属历史", createdAt: now), state = try seed([item])
        let id = UUID()
        let first = SyncAssignment(id: id, itemID: item.id, value: ProjectAssignment(previousProjectID: nil, projectID: nil, changedAt: now, reason: .manual))
        let second = SyncAssignment(id: id, itemID: item.id, value: ProjectAssignment(previousProjectID: nil, projectID: nil, changedAt: now.addingTimeInterval(10), reason: .manual))
        let changes = [SyncChange(writerID: UUID(), date: now, writes: [], assignments: [first]), SyncChange(writerID: UUID(), date: now, writes: [], assignments: [second])]
        XCTAssertThrowsError(try SyncGraph(state.changes + changes).projection())
    }

    @MainActor
    func testRemoteArchivePreservesDraftBackupAndReturnsToUnassignedAfterEditing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-archived-draft-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.6.0")
        let project = try store.createProject(name: "草稿中的项目")
        let item = TodoItem(title: "仍在编辑", projectID: project.id, createdAt: now)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        try store.initializeSync()
        let data = try store.loadBoardData()
        let board = BoardModel(items: data.items, projects: data.projects, persistence: store)
        board.selectScope(.project(project.id)); board.edit(try XCTUnwrap(store.storedItem(item.id)))
        var draft = try XCTUnwrap(board.draft); draft.notes = "尚未提交的文字不能丢"
        board.updateDraft(draft); XCTAssertTrue(board.flushDraft())
        let before = try store.syncContents()
        var archived = project; archived.status = .archived; archived.archivedAt = now
        let archiveChange = try XCTUnwrap(SyncBuilder.capture(before: before, after: SyncContents(items: before.items, projects: [archived], events: before.events), state: store.syncState()!))
        try store.acceptSync([archiveChange], cursors: [:])
        board.refreshFromSync()
        XCTAssertEqual(board.draft?.notes, draft.notes)
        XCTAssertEqual(board.selectedScope, .project(project.id))
        let backup = try BackupCodec.decode(BackupCodec.encode(store.archive()))
        XCTAssertEqual(backup.formatVersion, 3)
        XCTAssertEqual(try store.loadDraft()?.notes, draft.notes)
        board.submit(draft)
        XCTAssertNil(board.errorMessage)
        XCTAssertNil(board.draft)
        XCTAssertNil(try store.storedItem(item.id)?.projectID)
        XCTAssertEqual(try store.storedItem(item.id)?.notes, draft.notes)
        XCTAssertEqual(board.selectedScope, .unassigned)
        var newDraft = NoteDraft(now: now); newDraft.title = "归档期间新增"; newDraft.projectID = project.id
        board.submit(newDraft)
        XCTAssertNil(board.errorMessage)
        XCTAssertNil(try store.storedItem(newDraft.id)?.projectID)
    }

    func testOrdinaryEditorCannotSilentlyResolveUnseenConflictCandidates() throws {
        let item = TodoItem(title: "原题", createdAt: now)
        var state = try seed([item])
        var a = item, b = item; a.title = "候选 A"; b.title = "候选 B"
        state.changes += try [edit(state, original: item, updated: a), edit(state, original: item, updated: b)]
        let graph = try SyncGraph(state.changes)
        let shown = try XCTUnwrap(graph.projection().items.first)
        var changed = shown; changed.title = "普通编辑器里改的标题"
        let update = try edit(state, original: shown, updated: changed)
        let merged = try SyncGraph(state.changes + [update])
        XCTAssertEqual(try merged.conflicts().first?.candidates.count, 2)
    }

}
