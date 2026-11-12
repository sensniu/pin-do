import Foundation
import Combine
import Security

protocol SyncCredentials {
    func password(for key: String) throws -> String?
    func save(_ password: String, for key: String) throws
}
struct KeychainSyncCredentials: SyncCredentials {
    private var service: String { (Bundle.main.bundleIdentifier ?? "local.pindo.development") + ".webdav" }
    func password(for key: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SyncFailure.configuration("无法从钥匙串读取应用密码。") }
        return String(data: data, encoding: .utf8)
    }
    func save(_ password: String, for key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        let attributes = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var added = query; added[kSecValueData as String] = Data(password.utf8)
            added[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(added as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SyncFailure.configuration("应用密码未能保存到钥匙串。") }
    }
}

@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message = "未启用同步"
    @Published private(set) var error: String?
    @Published private(set) var conflicts: [SyncConflict] = []
    @Published private(set) var retainedItems: [TodoItem] = []
    @Published var showingSettings = false
    @Published var showingConflicts = false
    private(set) var repository: TodoRepository?
    private let credentials: any SyncCredentials
    private var scheduled: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var failures = 0
    private var rerun = false
    private var retryNotBefore: Date?
    private var firstPending: Date?
    var didReceive: (() -> Void)?
    init(credentials: any SyncCredentials = KeychainSyncCredentials()) { self.credentials = credentials }
    deinit { scheduled?.cancel(); polling?.cancel() }
    func attach(_ repository: TodoRepository) {
        self.repository = repository
        repository.onBusinessChange = { [weak self] in self?.changed() }
        refreshStatus()
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                self?.requestSync()
            }
        }
        requestSync()
    }
    var configuration: SyncConnection? { try? repository?.syncState()?.connection }
    var enabled: Bool { (try? repository?.syncState()?.enabled) == true }
    var lastSuccess: Date? { try? repository?.syncState()?.lastSuccess }
    func refreshStatus() {
        do {
            guard let state = try repository?.syncState() else { message = "未启用同步"; return }
            let graph = try SyncGraph(state.changes)
            conflicts = try graph.conflicts()
            let edited = Set(state.changes.flatMap(\.events).filter { $0.kind == .edited }.map(\.itemID))
            retainedItems = try graph.projection().items.filter { $0.status == .conflicted || ($0.status != .active && edited.contains($0.id)) }
            if !state.enabled { message = "同步已暂停" }
            else if state.pendingCount > 0 { message = "待同步 \(state.pendingCount) 项" }
            else if !state.inbox.isEmpty || state.received != state.cursors { message = "等待补齐同步数据" }
            else if !conflicts.isEmpty { message = "\(conflicts.count) 项冲突" }
            else { message = state.lastSuccess == nil ? "等待同步" : "已同步" }
        } catch { self.error = error.localizedDescription; message = "同步数据需要检查" }
    }
    func changed() {
        refreshStatus()
        guard enabled else { return }
        if busy { rerun = true; return }
        if firstPending == nil { firstPending = .now }
        let remaining = max(0, 30 - Date.now.timeIntervalSince(firstPending!))
        schedule(after: min(5, remaining))
    }
    private func schedule(after delay: Double) {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.requestSync()
        }
    }
    func requestSync() {
        guard enabled else { return }
        if busy { rerun = true; return }
        if let retryNotBefore, retryNotBefore > .now { schedule(after: retryNotBefore.timeIntervalSinceNow); return }
        scheduled?.cancel(); firstPending = nil
        Task { await run() }
    }
    func pause() {
        guard !busy, let repository else { return }
        do {
            if var state = try repository.syncState() { state.enabled = false; try repository.saveSyncState(state) }
            scheduled?.cancel(); refreshStatus()
        } catch { self.error = error.localizedDescription }
    }
    /// User explicitly selects a directory and connects/merges. No account-wide discovery.
    func connect(_ connection: SyncConnection, password: String) async throws {
        guard !busy, let repository else { throw SyncFailure.configuration("请等待当前同步完成。") }
        _ = try connection.root
        if let old = try repository.syncState(), old.libraryID != nil, old.connection != connection {
            throw SyncFailure.configuration("已有同步绑定。为保护待发送内容，本版请继续使用原服务器、账号和目录；更换同步库需独立迁移。")
        }
        busy = true; error = nil; message = "正在验证连接…"
        defer { busy = false; refreshStatus() }
        let effectivePassword = password.isEmpty ? try credentials.password(for: connection.credentialKey) ?? "" : password
        let client = try WebDAVClient(connection: connection, password: effectivePassword)
        try await client.directory("")
        try await client.probe()
        _ = try await client.children("")
        try credentials.save(effectivePassword, for: connection.credentialKey)
        try repository.initializeSync()
        didReceive?()
        guard var state = try repository.syncState() else { throw SyncFailure.invalidData }
        state.connection = connection; state.enabled = true
        try repository.saveSyncState(state)
        // Scheduled after the configuration operation releases the single-flight gate.
        schedule(after: 0.2)
    }
    private func run() async {
        guard enabled, !busy, let connection = configuration else { return }
        busy = true; rerun = false; error = nil; message = "正在同步…"
        do {
            let password = try credentials.password(for: connection.credentialKey) ?? ""
            let client = try WebDAVClient(connection: connection, password: password)
            let more = try await exchange(using: client)
            failures = 0; retryNotBefore = nil; busy = false; refreshStatus()
            if more || rerun { schedule(after: 5) }
        } catch {
            busy = false; failures += 1
            self.error = error.localizedDescription; message = "同步未完成"
            var retry = min(900, pow(2, Double(min(failures, 8))) * 15) + Double.random(in: 0...5)
            if case SyncFailure.throttled(let seconds) = error { retry = max(retry, seconds) }
            retryNotBefore = Date.now.addingTimeInterval(retry)
            // Authentication/unsupported/unsafe configuration needs user action, not a retry storm.
            if case SyncFailure.http(let code) = error, [401, 403].contains(code) { return }
            if case SyncFailure.unsafeServer = error { return }
            if case SyncFailure.unsupported = error { return }
            if case SyncFailure.wrongLibrary = error { return }
            schedule(after: retry)
        }
    }
    /// Also exercised with an in-memory DAV server; does not invoke UI or Keychain.
    func exchange(using dav: any DAVTransport) async throws -> Bool {
        guard let repository, var initial = try repository.syncState() else { throw SyncFailure.invalidData }
        let libraryResponse = try await dav.get("library.json")
        let library: SyncLibrary
        if libraryResponse.status == 404 {
            guard initial.libraryID == nil else { throw SyncFailure.wrongLibrary }
            let proposed = SyncLibrary(id: UUID())
            let bytes = try SyncCodec.wrap(proposed)
            let response = try await dav.request("PUT", path: "library.json", body: bytes, headers: ["If-None-Match": "*"])
            guard [200, 201, 204, 412].contains(response.status) else { throw SyncFailure.http(response.status) }
            let stored = try await dav.get("library.json")
            guard stored.status == 200 else { throw SyncFailure.http(stored.status) }
            library = try SyncCodec.unwrap(SyncLibrary.self, stored.data)
        } else {
            guard libraryResponse.status == 200 else { throw SyncFailure.http(libraryResponse.status) }
            library = try SyncCodec.unwrap(SyncLibrary.self, libraryResponse.data)
        }
        guard library.version == 1 else { throw SyncFailure.unsupported }
        guard initial.libraryID == nil || initial.libraryID == library.id else { throw SyncFailure.wrongLibrary }
        // Reload after every await before mutating durable state: local edits may have happened meanwhile.
        initial = try repository.syncState()!
        initial.libraryID = library.id; try repository.saveSyncState(initial)
        if initial.outgoing.sequence == 0 { try await dav.directory("writers") }
        let writer = initial.writerID.uuidString.lowercased()
        let writerPath = "writers/" + writer
        if initial.outgoing.sequence == 0 {
            try await dav.directory(writerPath)
            try await dav.create(writerPath + "/identity.json", data: SyncCodec.wrap(initial.writerID))
        }
        let discovered = try await dav.children("writers")
        let known = try repository.syncState()!
        guard discovered.contains(writer), Set(known.received.keys).union(known.cursors.keys).isSubset(of: Set(discovered)) else { throw SyncFailure.incompleteListing }
        var budget = 24, more = false
        for other in discovered.sorted() {
            guard let otherID = UUID(uuidString: other), other == otherID.uuidString.lowercased() else { throw SyncFailure.invalidData }
            let path = "writers/" + other
            let response = try await dav.get(path + "/head.json")
            if response.status == 404 {
                // A new writer may have no head yet. Losing a previously observed head is an error.
                let current = try repository.syncState()!
                guard (current.received[other] ?? current.cursors[other] ?? SyncCursor()).sequence == 0,
                      other != writer || current.outgoing.sequence == 0 else { throw SyncFailure.incompleteListing }
                continue
            }
            guard response.status == 200 else { throw SyncFailure.http(response.status) }
            let head = try SyncCodec.unwrap(SyncHead.self, response.data)
            guard head.version == 1, head.libraryID == library.id, head.writerID == otherID, head.cursor.sequence >= 0 else { throw SyncFailure.unsupported }
            let state = try repository.syncState()!
            var cursor = state.received[other] ?? state.cursors[other] ?? SyncCursor()
            guard head.cursor.sequence >= cursor.sequence else { throw SyncFailure.identityCollision }
            if head.cursor.sequence == cursor.sequence {
                guard head.cursor.checksum == cursor.checksum else { throw SyncFailure.identityCollision }
            }
            while cursor.sequence < head.cursor.sequence && budget > 0 {
                let sequence = cursor.sequence + 1
                let packetResponse = try await dav.get(Self.packetPath(writer: other, sequence: sequence))
                guard packetResponse.status == 200 else { throw SyncFailure.http(packetResponse.status) }
                let packet = try SyncCodec.unwrap(SyncPacket.self, packetResponse.data)
                guard packet.version == 1, packet.libraryID == library.id, packet.writerID == otherID,
                      packet.sequence == sequence, packet.previous == cursor.checksum else { throw SyncFailure.invalidData }
                cursor = SyncCursor(sequence: sequence, checksum: SyncCodec.hash(packetResponse.data))
                try repository.stageReceived(packet.changes, writer: other, cursor: cursor)
                budget -= 1
            }
            if cursor.sequence == head.cursor.sequence {
                guard cursor.checksum == head.cursor.checksum else { throw SyncFailure.invalidData }
            } else { more = true }
        }
        do { try repository.applyReceived(); didReceive?() }
        catch SyncFailure.missingDependency { more = true }
        // A single sealed packet per round bounds request count and makes retries byte-for-byte stable.
        var state = try repository.syncState()!
        if state.pending == nil {
            let changes = Array(state.changes.filter { state.outboxIDs.contains($0.id) }.prefix(64))
            if !changes.isEmpty {
                let packet = SyncPacket(libraryID: library.id, writerID: state.writerID, sequence: state.outgoing.sequence + 1, previous: state.outgoing.checksum, changes: changes)
                state.pending = try SyncCodec.wrap(packet); try repository.saveSyncState(state)
            }
        }
        if let bytes = state.pending {
            let packet = try SyncCodec.unwrap(SyncPacket.self, bytes)
            guard packet.libraryID == library.id, packet.writerID == state.writerID,
                  packet.sequence == state.outgoing.sequence + 1, packet.previous == state.outgoing.checksum else { throw SyncFailure.identityCollision }
            let local = Dictionary(uniqueKeysWithValues: state.changes.map { ($0.id, $0) })
            for change in packet.changes {
                guard let stored = local[change.id], try SyncCodec.encode(stored) == SyncCodec.encode(change) else { throw SyncFailure.identityCollision }
            }
            let path = Self.packetPath(writer: writer, sequence: packet.sequence)
            if packet.sequence == 1 { try await dav.directory(writerPath + "/segments") }
            if (packet.sequence - 1) % 128 == 0 { try await dav.directory(writerPath + "/segments/\((packet.sequence - 1) / 128)") }
            try await dav.create(path, data: bytes)
            let cursor = SyncCursor(sequence: packet.sequence, checksum: SyncCodec.hash(bytes))
            let headPath = writerPath + "/head.json"
            let old = try await dav.get(headPath)
            var headers: [String: String]
            if old.status == 404 { headers = ["If-None-Match": "*"] }
            else {
                guard old.status == 200, let etag = old.etag, !etag.hasPrefix("W/") else { throw SyncFailure.unsafeServer }
                let oldHead = try SyncCodec.unwrap(SyncHead.self, old.data)
                guard oldHead.libraryID == library.id, oldHead.writerID == state.writerID, oldHead.version == 1,
                      oldHead.cursor == state.outgoing || oldHead.cursor == cursor else { throw SyncFailure.identityCollision }
                headers = ["If-Match": etag]
            }
            let headBytes = try SyncCodec.wrap(SyncHead(libraryID: library.id, writerID: state.writerID, cursor: cursor))
            let update = try await dav.request("PUT", path: headPath, body: headBytes, headers: headers)
            guard [200, 201, 204, 412].contains(update.status) else { throw SyncFailure.http(update.status) }
            let verified = try await dav.get(headPath)
            guard verified.status == 200, verified.data == headBytes else { throw SyncFailure.identityCollision }
            state = try repository.syncState()!
            guard state.pending == bytes else { throw SyncFailure.identityCollision }
            state.published.formUnion(packet.changes.map(\.id)); state.outboxIDs.subtract(packet.changes.map(\.id)); state.outgoing = cursor; state.pending = nil
            state.cursors[writer] = cursor; state.received[writer] = cursor
            try repository.saveSyncState(state)
        } else {
            // Detect a restored/cloned writer even if there is currently no local work to publish.
            let current = try repository.syncState()!
            if let seen = current.received[writer], seen != current.outgoing { throw SyncFailure.identityCollision }
        }
        state = try repository.syncState()!
        more = more || state.pendingCount > 0 || !state.inbox.isEmpty
        if !more { state.lastSuccess = .now; try repository.saveSyncState(state) }
        return more
    }
    static func packetPath(writer: String, sequence: Int) -> String {
        "writers/\(writer)/segments/\((sequence - 1) / 128)/\(sequence).json"
    }
    func resolve(_ conflict: SyncConflict, candidate: SyncWrite) {
        do { try repository?.resolveSyncConflict(conflict, candidate: candidate); didReceive?(); refreshStatus() }
        catch { self.error = error.localizedDescription }
    }
    func title(for entity: String) -> String {
        guard let state = try? repository?.syncState(), let graph = try? SyncGraph(state.changes) else { return "同步事项" }
        return (try? graph.value(String.self, entity, entity.hasPrefix("todo:") ? "title" : "name")) ?? "同步事项"
    }
    func describe(_ write: SyncWrite) -> String {
        switch write.field {
        case "title", "notes", "name": return (try? SyncCodec.decode(String.self, write.value)) ?? ""
        case "deadline": return (try? SyncCodec.decode(Date?.self, write.value))?.formatted(date: .abbreviated, time: .shortened) ?? "无截止时间"
        case "stars": return "\((try? SyncCodec.decode(Int.self, write.value)) ?? 1) 颗星"
        case "lifecycle":
            let status = (try? SyncCodec.decode(SyncLife.self, write.value))?.status ?? ""
            return ["active": "未完成", "completed": "已完成", "abandoned": "已放弃", "archived": "已归档", "deleted": "已删除"][status] ?? status
        case "color": return (try? SyncCodec.decode(ProjectColor.self, write.value))?.hex ?? "颜色"
        case "membership":
            guard let id = (try? SyncCodec.decode(SyncMembership.self, write.value))?.projectID else { return "未分配项目" }
            return title(for: SyncGraph.entity("project", id))
        default: return String(data: write.value, encoding: .utf8) ?? "来源记录"
        }
    }
}
