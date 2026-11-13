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
        do { try repository.prepareCurrentSync() } catch { self.error = error.localizedDescription; return }
        didReceive?()
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
            let edited = Set(state.changes.flatMap { $0.endedEdits ?? [] })
            retainedItems = try graph.projection().items.filter { $0.status == .conflicted || ($0.status != .active && edited.contains($0.id)) }
            if !state.enabled { message = "同步已暂停" }
            else if state.pendingCount > 0 { message = "待同步 \(state.pendingCount) 项" }
            else if state.current?.cleanupPending == true { message = "待清理同步工作" }
            else if !(state.current?.inbox.isEmpty ?? true) || !state.inbox.isEmpty || state.received != state.cursors { message = "等待补齐同步数据" }
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
        let previous = try repository.syncState()
        if let old = previous, old.libraryID != nil, old.connection != connection {
            throw SyncFailure.configuration("已有同步绑定。为保护待发送内容，本版请继续使用原服务器、账号和目录；更换同步库需独立迁移。")
        }
        busy = true; error = nil; message = "正在验证连接…"
        defer { busy = false; refreshStatus() }
        let effectivePassword = password.isEmpty ? try credentials.password(for: connection.credentialKey) ?? "" : password
        let client = try WebDAVClient(connection: connection, password: effectivePassword, installationID: previous?.writerID ?? UUID())
        try await client.prepareRootHierarchy()
        let creationMode = try await client.probe()
        _ = try await client.children("")
        try credentials.save(effectivePassword, for: connection.credentialKey)
        try repository.initializeSync()
        didReceive?()
        guard var state = try repository.syncState() else { throw SyncFailure.invalidData }
        if state.libraryID == nil && state.connection != connection { state.proposedLibraryID = nil }
        state.connection = connection; state.enabled = true; state.remoteCreationMode = creationMode; state.remoteSafetyVersion = 4
        try repository.saveSyncState(state)
        // Scheduled after the configuration operation releases the single-flight gate.
        schedule(after: 0.2)
    }
    private func run() async {
        guard enabled, !busy, let connection = configuration else { return }
        busy = true; rerun = false; error = nil; message = "正在同步…"
        do {
            let password = try credentials.password(for: connection.credentialKey) ?? ""
            let client = try WebDAVClient(connection: connection, password: password,
                creationMode: repository?.syncState()?.remoteSafetyVersion == 4 ? repository?.syncState()?.remoteCreationMode : nil, installationID: repository?.syncState()?.writerID ?? UUID())
            if try repository?.syncState()?.remoteSafetyVersion != 4 {
                try await client.prepareRootHierarchy()
                let mode = try await client.probe()
                if var state = try repository?.syncState() { state.remoteCreationMode = mode; state.remoteSafetyVersion = 4; try repository?.saveSyncState(state) }
            }
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
            if case SyncFailure.serverCapability = error { return }
            if case SyncFailure.unsupported = error { return }
            if case SyncFailure.wrongLibrary = error { return }
            schedule(after: retry)
        }
    }
    /// Protocol v3: immutable recoverable work, conditional publication, and verified cleanup.
    func exchange(using dav: any DAVTransport) async throws -> Bool {
        guard let repository else { throw SyncFailure.invalidData }
        try repository.prepareCurrentSync()
        guard var initial = try repository.syncState() else { throw SyncFailure.invalidData }
        let response = try await dav.get("library.json")
        let library: SyncLibrary
        if response.status == 404 {
            if let client = dav as? WebDAVClient { try await client.prepareRootHierarchy() }
            else { try await dav.directory("") }
            if initial.proposedLibraryID == nil {
                initial.proposedLibraryID = UUID(); try repository.saveSyncState(initial)
            }
            do { try await dav.create("library.json", data: SyncCodec.wrap(SyncLibrary(id: initial.proposedLibraryID!))) }
            catch SyncFailure.identityCollision { }
            let stored = try await dav.get("library.json")
            guard stored.status == 200 else { throw SyncFailure.http(stored.status) }
            library = try SyncCodec.unwrap(SyncLibrary.self, stored.data)
        } else {
            guard response.status == 200 else { throw SyncFailure.http(response.status) }
            library = try SyncCodec.unwrap(SyncLibrary.self, response.data)
        }
        guard library.version == 3 else { throw SyncFailure.unsupported }
        if response.status == 200, let proposal = initial.proposedLibraryID {
            // Recover a first-create staging cleanup after an interrupted request or another creator winning.
            do { try await dav.create("library.json", data: SyncCodec.wrap(SyncLibrary(id: proposal))) }
            catch SyncFailure.identityCollision { }
        }
        if initial.libraryID != library.id {
            let existingIndex = try await dav.get("index.json")
            if existingIndex.status != 404 { _ = try decodeIndex(existingIndex, library: library.id) }
            try repository.resetCurrentCloud(library.id)
        }
        try await dav.directory("records")
        try await dav.directory("_work")
        try await recoverCloudWork(dav, library: library.id)
        let index = try await readCurrentIndex(dav, library: library.id)
        var count = 0, more = false
        for (entity, revision) in index.records.sorted(by: { $0.key < $1.key }) {
            let local = try repository.syncState()!.current!
            if max(local.seen[entity, default: 0], local.inbox[entity]?.revision ?? 0) >= revision { continue }
            if count >= 24 { more = true; break }
            let stored = try await dav.get(SyncCurrent.path(entity))
            let record = try decodeCurrent(stored, entity: entity, library: library.id)
            guard record.revision >= revision else { throw SyncFailure.invalidData }
            try repository.stageCurrent([record]); count += 1
        }
        do { try repository.applyReceived(); didReceive?() }
        catch SyncFailure.missingDependency { more = true }
        let sealed = try repository.sealCurrent()
        for mutation in sealed.prefix(24) {
            let record = try await publishWork(mutation, dav: dav, library: library.id)
            try repository.stageCurrent([record]); try repository.acknowledgeCurrent(mutation)
            do { try repository.applyReceived(); didReceive?() }
            catch SyncFailure.missingDependency { more = true }
        }
        var state = try repository.syncState()!
        more = more || state.pendingCount > 0 || !state.current!.inbox.isEmpty || state.current!.cleanupPending == true
        if !more { state.lastSuccess = .now; try repository.saveSyncState(state) }
        return more
    }
    func readCurrentIndex(_ dav: any DAVTransport, library: UUID) async throws -> SyncCurrentIndex {
        let response = try await dav.get("index.json")
        if response.status == 404 {
            guard try repository?.syncState()?.current?.indexEstablished != true else {
                throw SyncFailure.configuration("云端索引缺失，本地内容已保留。若要重新初始化，请完整清空专用云目录（包括 library.json）。")
            }
            do { try await dav.create("index.json", data: SyncCodec.wrap(SyncCurrentIndex(libraryID: library))) }
            catch SyncFailure.identityCollision { }
            let stored = try await dav.get("index.json")
            let index = try decodeIndex(stored, library: library)
            try rememberIndex(index)
            return index
        }
        let index = try decodeIndex(response, library: library)
        try rememberIndex(index)
        return index
    }
    private func rememberIndex(_ index: SyncCurrentIndex) throws {
        guard var state = try repository?.syncState() else { throw SyncFailure.invalidData }
        let known = state.current!.indexWatermarks
        guard known.allSatisfy({ index.records[$0.key, default: -1] >= $0.value }) else { throw SyncFailure.incompleteListing }
        state.current!.indexEstablished = true; state.current!.indexWatermarks = index.records
        try repository?.saveSyncState(state)
    }
    func decodeIndex(_ response: DAVResponse, library: UUID) throws -> SyncCurrentIndex {
        guard response.status == 200 else { throw SyncFailure.http(response.status) }
        guard response.data.count <= SyncCurrent.maxIndexBytes else { throw SyncFailure.invalidData }
        let index = try SyncCodec.unwrap(SyncCurrentIndex.self, response.data)
        guard index.version == 3, index.libraryID == library,
              index.records.allSatisfy({ SyncCurrent.validEntity($0.key) && $0.value > 0 }) else { throw SyncFailure.invalidData }
        return index
    }
    func decodeCurrent(_ response: DAVResponse, entity: String, library: UUID) throws -> SyncEntityRecord {
        guard SyncCurrent.validEntity(entity) else { throw SyncFailure.invalidData }
        guard response.status == 200 else { throw SyncFailure.http(response.status) }
        guard response.data.count <= SyncCurrent.maxRecordBytes else { throw SyncFailure.invalidData }
        let record = try SyncCodec.unwrap(SyncEntityRecord.self, response.data)
        let entityID = UUID(uuidString: String(entity.split(separator: ":").last!))!
        guard record.version == 3, record.libraryID == library, record.entity == entity, record.revision > 0,
              !record.change.writes.isEmpty, record.change.writes.allSatisfy({ $0.entity == entity && $0.parents.isEmpty }),
              record.change.events.allSatisfy({ $0.itemID == entityID }), record.change.assignments.allSatisfy({ $0.itemID == entityID }),
              record.receipts.allSatisfy({ UUID(uuidString: $0.key)?.uuidString.lowercased() == $0.key && $0.value > 0 }) else { throw SyncFailure.invalidData }
        guard Set(record.change.writes.map(\.field)).isSuperset(of: SyncGraph.fields(for: entity.hasPrefix("todo:") ? "todo" : "project")),
              let proofs = record.receiptOperations, Set(proofs.keys) == Set(record.receipts.keys),
              proofs.allSatisfy({ record.receipts[$0.key] == $0.value.sequence && $0.value.digest.count == 64 }),
              let publication = record.publication, proofs[publication.writerID.uuidString.lowercased()] == publication.receipt else { throw SyncFailure.identityCollision }
        if let state = try repository?.syncState(), let current = state.current {
            let received = record.receipts[state.writerID.uuidString.lowercased(), default: 0]
            guard received >= current.acknowledged[entity, default: 0], received <= current.counters[entity, default: 0] else { throw SyncFailure.identityCollision }
        }
        for write in record.change.writes { try SyncGraph.validate(write) }
        let tokens = Set(record.change.writes.filter { $0.field == "lifecycle" }.map(\.id))
        guard record.change.events.allSatisfy({ tokens.contains($0.id) && [.completed, .abandoned].contains($0.kind) }) else { throw SyncFailure.invalidData }
        if entity.hasPrefix("project:") {
            for write in record.change.writes where write.field == "lifecycle" {
                let life = try SyncCodec.decode(SyncLife.self, write.value)
                guard life.retired != nil, life.transition != nil, life.observed != nil else { throw SyncFailure.invalidData }
            }
        }
        return record
    }
    func publishCurrent(_ mutation: SyncMutation, dav: any DAVTransport, library: UUID) async throws -> SyncEntityRecord {
        let path = try SyncCurrent.path(mutation.entity)
        for _ in 0..<5 {
            let old = try await dav.get(path)
            if old.status == 404 {
                let index = try decodeIndex(await dav.get("index.json"), library: library)
                guard index.records[mutation.entity] == nil, try repository?.syncState()?.current?.seen[mutation.entity] == nil,
                      Set(mutation.change.writes.map(\.field)).isSuperset(of: SyncGraph.fields(for: mutation.entity.hasPrefix("todo:") ? "todo" : "project")) else {
                    throw SyncFailure.configuration("云端已有事项的记录缺失，本地完整内容和未确认修改已保留。")
                }
            }
            let record = old.status == 404 ? SyncEntityRecord(libraryID: library, entity: mutation.entity,
                change: SyncChange(writerID: mutation.writerID, date: .now, writes: [])) : try decodeCurrent(old, entity: mutation.entity, library: library)
            let next = try SyncCurrent.merging(mutation, into: record)
            if next.revision == record.revision { return record }
            let bytes = try SyncCurrent.encoded(next, limit: SyncCurrent.maxRecordBytes)
            do {
                if old.status == 404 { try await dav.create(path, data: bytes) }
                else {
                    guard let tag = DAVProbe.usableTag(old.etag) else { throw SyncFailure.serverCapability(stage: "读取最新记录 ETag", detail: "记录缺少可用于版本校验的 ETag。", status: old.status) }
                    let update = try await dav.request("PUT", path: path, body: bytes, headers: ["If-Match": tag])
                    if [409, 412].contains(update.status) { continue }
                    guard [200, 201, 204].contains(update.status) else { throw SyncFailure.http(update.status) }
                }
            } catch SyncFailure.identityCollision { continue }
            catch {
                if let check = try? await dav.get(path), let saved = try? decodeCurrent(check, entity: mutation.entity, library: library),
                   saved.receipts[mutation.writerID.uuidString.lowercased(), default: 0] >= mutation.sequence {
                    _ = try SyncCurrent.merging(mutation, into: saved)
                    return saved
                }
                throw error
            }
            let saved = try decodeCurrent(await dav.get(path), entity: mutation.entity, library: library)
            if saved.receipts[mutation.writerID.uuidString.lowercased(), default: 0] >= mutation.sequence { _ = try SyncCurrent.merging(mutation, into: saved); return saved }
        }
        throw SyncFailure.configuration("其他设备正在更新同一事项，本地修改已保留，请稍后重试。")
    }
    func advertiseCurrent(_ records: [SyncEntityRecord], dav: any DAVTransport, library: UUID) async throws {
        for _ in 0..<5 {
            let old = try await dav.get("index.json")
            var index = try decodeIndex(old, library: library)
            try rememberIndex(index)
            var changed = false
            for record in records where record.revision > index.records[record.entity, default: 0] {
                index.records[record.entity] = record.revision; changed = true
            }
            if !changed { try rememberIndex(index); return }
            guard let tag = DAVProbe.usableTag(old.etag) else { throw SyncFailure.serverCapability(stage: "读取最新索引 ETag", detail: "索引缺少可用于版本校验的 ETag。", status: old.status) }
            let bytes = try SyncCurrent.encoded(index, limit: SyncCurrent.maxIndexBytes)
            do {
                let update = try await dav.request("PUT", path: "index.json", body: bytes, headers: ["If-Match": tag])
                if [409, 412].contains(update.status) { continue }
                guard [200, 201, 204].contains(update.status) else { throw SyncFailure.http(update.status) }
            } catch {
                if let check = try? await dav.get("index.json"), let saved = try? decodeIndex(check, library: library),
                   records.allSatisfy({ saved.records[$0.entity, default: 0] >= $0.revision }) { try rememberIndex(saved); return }
                throw error
            }
            let saved = try decodeIndex(await dav.get("index.json"), library: library)
            if records.allSatisfy({ saved.records[$0.entity, default: 0] >= $0.revision }) { try rememberIndex(saved); return }
        }
        throw SyncFailure.configuration("云端索引正在被其他设备更新，待发送内容已保留，请稍后重试。")
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
