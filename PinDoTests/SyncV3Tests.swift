import XCTest

final class SyncV3Tests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pindo-v3-\(UUID())") }

    @MainActor
    func testThousandEditsKeepOneBodyAndNoAuditEvents() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TodoRepository(paths: AppPaths(root: folder), appVersion: "0.10.0")
        var item = TodoItem(title: "当前事项", createdAt: stamp)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: stamp), clearDraft: true)
        try store.initializeSync()
        for index in 0..<1000 {
            item = try XCTUnwrap(store.storedItem(item.id)); item.notes = "latest-body-\(index)"
            try store.commit(item, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: stamp), clearDraft: true)
        }
        let state = try XCTUnwrap(store.syncState())
        XCTAssertTrue(try store.records(in: "event").isEmpty)
        XCTAssertEqual(state.changes.count, 1)
        XCTAssertEqual(state.changes.flatMap(\.writes).filter { $0.field == "notes" }.count, 1)
        XCTAssertEqual(state.current?.outbox.count, 1)
        XCTAssertEqual(state.current?.outbox.values.flatMap { $0.change.writes }.filter { $0.field == "notes" }.count, 1)
        let sync = SyncCoordinator(), dav = MemoryDAV(); sync.attach(store)
        _ = try await sync.exchange(using: dav)
        let paths = await dav.files.keys.sorted()
        XCTAssertEqual(paths.count, 3)
        XCTAssertFalse(paths.contains { $0.hasPrefix("_work/") })
        let response = try await dav.get(SyncCurrent.path(SyncGraph.entity("todo", item.id)))
        let record = try SyncCodec.unwrap(SyncEntityRecord.self, response.data)
        XCTAssertTrue(record.change.events.isEmpty)
        XCTAssertEqual(try SyncCodec.decode(String.self, XCTUnwrap(record.change.writes.first { $0.field == "notes" }).value), "latest-body-999")
        try await store.createAutomaticBackupNow()
        let files = try FileManager.default.contentsOfDirectory(atPath: store.paths.backups.path)
        XCTAssertEqual(files, ["recovery.latest.pindobackup"])
    }

    @MainActor
    func testProjectEpochsReplaceFullLifecycleHistory() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TodoRepository(paths: AppPaths(root: folder), appVersion: "0.10.0")
        let project = try store.createProject(name: "不累计项目历史")
        let item = TodoItem(title: "原项目归属", projectID: project.id, createdAt: stamp)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: stamp), clearDraft: true)
        try store.initializeSync()
        for _ in 0..<100 { _ = try store.archiveProject(id: project.id); _ = try store.restoreProject(id: project.id) }
        let state = try XCTUnwrap(store.syncState()), entity = SyncGraph.entity("project", project.id)
        let lives = state.changes.flatMap(\.writes).filter { $0.entity == entity && $0.field == "lifecycle" }
        XCTAssertEqual(lives.count, 1); XCTAssertTrue(lives[0].parents.isEmpty)
        let life = try SyncCodec.decode(SyncLife.self, lives[0].value)
        XCTAssertEqual(life.retired?.count, 1); XCTAssertNotNil(life.generation)
        XCTAssertEqual(state.current?.outbox[entity]?.change.writes.filter { $0.field == "lifecycle" }.count, 1)
        XCTAssertNil(try store.storedItem(item.id)?.projectID)
        XCTAssertEqual(try store.storedItem(item.id)?.projectAssignments.count, 1)
        XCTAssertEqual(try store.storedItem(item.id)?.projectAssignments.first?.reason, .archived)
        XCTAssertTrue(try store.records(in: "event").isEmpty)
        _ = try BackupCodec.decode(BackupCodec.encode(store.archive()))
    }

    @MainActor
    func testAnotherDeviceFinishesAnInterruptedUpload() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let a = try TodoRepository(paths: AppPaths(root: folder.appendingPathComponent("a")), appVersion: "0.10.0")
        let b = try TodoRepository(paths: AppPaths(root: folder.appendingPathComponent("b")), appVersion: "0.10.0")
        try a.initializeSync(); try b.initializeSync()
        let ca = SyncCoordinator(), cb = SyncCoordinator(), dav = MemoryDAV(); ca.attach(a); cb.attach(b)
        await dav.setUnsafeDelete()
        _ = try await ca.exchange(using: dav)
        let item = TodoItem(title: "原设备已中断", notes: "完整待发正文", createdAt: stamp)
        try a.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: stamp), clearDraft: true)
        let path = try SyncCurrent.path(SyncGraph.entity("todo", item.id))
        await dav.setBeforeFailure(path)
        do { _ = try await ca.exchange(using: dav); XCTFail("Expected upload interruption") } catch { }
        XCTAssertEqual(try a.syncState()?.pendingCount, 1)
        let pending = await dav.files.keys.filter { $0.hasSuffix(".intent.json") }; XCTAssertEqual(pending.count, 1)
        _ = try await cb.exchange(using: dav)
        XCTAssertEqual(try b.storedItem(item.id)?.notes, item.notes)
        XCTAssertEqual(try a.syncState()?.pendingCount, 1) // The other device cannot edit a local database.
        let clean = await dav.files.keys.filter { $0.hasPrefix("_work/") }; XCTAssertTrue(clean.isEmpty)
        _ = try await ca.exchange(using: dav)
        XCTAssertEqual(try a.syncState()?.pendingCount, 0)
        let remote = try await dav.get(path)
        XCTAssertEqual(try SyncCodec.unwrap(SyncEntityRecord.self, remote.data).revision, 1)
    }

    @MainActor
    func testAnotherDeviceRepairsTheUnpublishedIndex() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let a = try TodoRepository(paths: AppPaths(root: folder.appendingPathComponent("a")), appVersion: "0.10.0")
        let b = try TodoRepository(paths: AppPaths(root: folder.appendingPathComponent("b")), appVersion: "0.10.0")
        try a.initializeSync(); try b.initializeSync()
        let ca = SyncCoordinator(), cb = SyncCoordinator(), dav = MemoryDAV(); ca.attach(a); cb.attach(b)
        await dav.setUnsafeDelete()
        _ = try await ca.exchange(using: dav)
        let item = TodoItem(title: "记录已写入，索引未写入", createdAt: stamp)
        try a.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: stamp), clearDraft: true)
        await dav.setBeforeFailure("index.json")
        do { _ = try await ca.exchange(using: dav); XCTFail("Expected index interruption") } catch { }
        let before = try await dav.get("index.json")
        XCTAssertTrue(try SyncCodec.unwrap(SyncCurrentIndex.self, before.data).records.isEmpty)
        // A peer may serialize the outer JSON differently; reclaim the actual received work URL.
        let workFiles = await dav.files
        let oldWork = try XCTUnwrap(workFiles.first { $0.key.hasSuffix(".intent.json") })
        let pretty = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: oldWork.value), options: [.prettyPrinted, .sortedKeys])
        _ = try await dav.request("DELETE", path: oldWork.key, body: nil, headers: [:])
        let writer = try XCTUnwrap(a.syncState()).writerID
        await dav.overwrite(SyncWorkFile(owner: writer, data: pretty, kind: .intent).path, pretty)
        _ = try await cb.exchange(using: dav)
        XCTAssertEqual(try b.storedItem(item.id)?.title, item.title)
        let after = try await dav.get("index.json"), record = try await dav.get(SyncCurrent.path(SyncGraph.entity("todo", item.id)))
        XCTAssertEqual(try SyncCodec.unwrap(SyncCurrentIndex.self, after.data).records.count, 1)
        XCTAssertEqual(try SyncCodec.unwrap(SyncEntityRecord.self, record.data).revision, 1)
        let work = await dav.files.keys.filter { $0.hasPrefix("_work/") }; XCTAssertTrue(work.isEmpty)
    }

    @MainActor
    func testCompleteIntentInPayloadRecoversAnInterruptedMove() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let a = try TodoRepository(paths: AppPaths(root: folder.appendingPathComponent("a")), appVersion: "0.10.0")
        let b = try TodoRepository(paths: AppPaths(root: folder.appendingPathComponent("b")), appVersion: "0.10.0")
        try a.initializeSync(); try b.initializeSync()
        let ca = SyncCoordinator(), cb = SyncCoordinator(), dav = MemoryDAV(); ca.attach(a); cb.attach(b)
        await dav.setUnsafeDelete()
        _ = try await ca.exchange(using: dav)
        let item = TodoItem(title: "意图 MOVE 中断", createdAt: stamp)
        try a.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: stamp), clearDraft: true)
        let mutation = try XCTUnwrap(a.sealCurrent().first), library = try XCTUnwrap(a.syncState()?.libraryID)
        let intent = try SyncWorkIntent(libraryID: library, mutation: mutation)
        let bytes = try SyncCodec.wrap(intent)
        await dav.overwrite(SyncWorkFile(owner: mutation.writerID, data: bytes, kind: .payload).path, bytes)
        _ = try await cb.exchange(using: dav)
        XCTAssertEqual(try b.storedItem(item.id)?.title, item.title)
        let work = await dav.files.keys.filter { $0.hasPrefix("_work/") }; XCTAssertTrue(work.isEmpty)
    }

    func testOldWorkCleanupCannotDeleteANewerOperationWithoutDeleteConditions() async throws {
        let dav = MemoryDAV(), owner = UUID(), first = Data("first".utf8), second = Data("second".utf8)
        await dav.setUnsafeDelete()
        let oldPath = SyncWorkFile(owner: owner, data: first, kind: .payload).path
        let newPath = SyncWorkFile(owner: owner, data: second, kind: .payload).path
        XCTAssertNotEqual(oldPath, newPath)
        await dav.overwrite(oldPath, first)
        let old = try await dav.get(oldPath)
        await dav.overwrite(newPath, second)
        let removed = try await dav.deleteWorkFile(oldPath, response: old)
        XCTAssertTrue(removed)
        let current = try await dav.get(newPath); XCTAssertEqual(current.data, second)
    }

    func testLostDeleteResponseAndRepeatedDeleteAreIdempotent() async throws {
        let dav = MemoryDAV(), bytes = Data("owned bytes".utf8)
        await dav.setUnsafeDelete()
        let path = SyncWorkFile(owner: UUID(), data: bytes, kind: .payload).path
        await dav.overwrite(path, bytes)
        let response = try await dav.get(path)
        await dav.loseDeleteResponse(path)
        let removed = try await dav.deleteWorkFile(path, response: response)
        let again = try await dav.deleteWorkFile(path, response: response)
        XCTAssertTrue(removed); XCTAssertTrue(again)
    }

    @MainActor
    func testCleanupFailureKeepsPendingInputUntilRecovery() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TodoRepository(paths: AppPaths(root: folder), appVersion: "0.10.0")
        try store.initializeSync()
        let sync = SyncCoordinator(), dav = MemoryDAV(); sync.attach(store)
        _ = try await sync.exchange(using: dav)
        let item = TodoItem(title: "清理失败仍保留正文", notes: "不能提前确认", createdAt: stamp)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: stamp), clearDraft: true)
        await dav.denyDeletes(true)
        do { _ = try await sync.exchange(using: dav); XCTFail("Cleanup must be confirmed") } catch { }
        XCTAssertEqual(try store.storedItem(item.id)?.notes, item.notes)
        XCTAssertEqual(try store.syncState()?.pendingCount, 1)
        await dav.denyDeletes(false)
        _ = try await sync.exchange(using: dav)
        XCTAssertEqual(try store.syncState()?.pendingCount, 0)
        let response = try await dav.get(SyncCurrent.path(SyncGraph.entity("todo", item.id)))
        XCTAssertEqual(try SyncCodec.unwrap(SyncEntityRecord.self, response.data).revision, 1)
        let work = await dav.files.keys.filter { $0.hasPrefix("_work/") }; XCTAssertTrue(work.isEmpty)
    }

    func testIgnoredDeleteConditionUsesImmutableWorkInsteadOfRejectingProvider() async throws {
        BootstrapDAVProtocol.server.reset(nutstore: true, unsafeDelete: true)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BootstrapDAVProtocol.self]
        let client = try WebDAVClient(connection: SyncConnection(server: "https://bootstrap.invalid/dav/", directory: "v3", username: "test"), password: "test-only", configuration: config)
        try await client.prepareRootHierarchy()
        let mode = try await client.probe()
        XCTAssertEqual(mode, .exclusiveMove)
        XCTAssertTrue(BootstrapDAVProtocol.server.filePaths.isEmpty)
    }

    @MainActor
    func testNutstoreStyleFixedSlotsLeaveNoHistoryOrWorkFiles() async throws {
        BootstrapDAVProtocol.server.reset(nutstore: true, unsafeDelete: true)
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TodoRepository(paths: AppPaths(root: folder), appVersion: "0.10.0")
        var item = TodoItem(title: "固定工作槽位", createdAt: stamp)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: stamp), clearDraft: true)
        try store.initializeSync()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BootstrapDAVProtocol.self]
        let client = try WebDAVClient(connection: SyncConnection(server: "https://bootstrap.invalid/dav/", directory: "v3", username: "test"), password: "test-only", configuration: config, installationID: store.syncState()!.writerID)
        try await client.prepareRootHierarchy(); try await client.probe()
        let path = try SyncCurrent.path(SyncGraph.entity("todo", item.id))
        BootstrapDAVProtocol.server.failMoveOnce(to: "/dav/v3/" + path)
        let sync = SyncCoordinator(); sync.attach(store)
        _ = try await sync.exchange(using: client)
        for index in 0..<20 {
            item = try XCTUnwrap(store.storedItem(item.id)); item.notes = "value-\(index)"
            try store.commit(item, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: stamp), clearDraft: true)
            _ = try await sync.exchange(using: client)
        }
        let files = BootstrapDAVProtocol.server.filePaths
        XCTAssertEqual(files.count, 3)
        XCTAssertFalse(files.contains { $0.contains("_work/") || $0.contains("pindo-upload") || $0.contains("writers/") })
    }

    @MainActor
    func testMissingKnownRecordCannotBeReplacedWithAPartialEdit() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TodoRepository(paths: AppPaths(root: folder), appVersion: "0.10.0")
        var item = TodoItem(title: "不能被部分备注替代", createdAt: stamp)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: stamp), clearDraft: true)
        try store.initializeSync()
        let sync = SyncCoordinator(), dav = MemoryDAV(); sync.attach(store)
        _ = try await sync.exchange(using: dav)
        item = try XCTUnwrap(store.storedItem(item.id)); item.notes = "新备注完整保留本地"
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: stamp), clearDraft: true)
        let path = try SyncCurrent.path(SyncGraph.entity("todo", item.id))
        _ = try await dav.request("DELETE", path: path, body: nil, headers: [:])
        do { _ = try await sync.exchange(using: dav); XCTFail("Lost record silently recreated") } catch { }
        let remote = try await dav.get(path); XCTAssertEqual(remote.status, 404)
        XCTAssertEqual(try store.storedItem(item.id)?.notes, item.notes)
        XCTAssertEqual(try store.syncState()?.pendingCount, 1)
    }

    @MainActor
    func testUndoCyclesKeepOnlyCurrentlyEffectiveCompletionTokens() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TodoRepository(paths: AppPaths(root: folder), appVersion: "0.10.0")
        let original = TodoItem(title: "撤回不保存永久事件链", createdAt: stamp)
        try store.commit(original, event: TodoEvent(itemID: original.id, kind: .created, occurredAt: stamp), clearDraft: true)
        try store.initializeSync()
        for _ in 0..<50 {
            var item = try XCTUnwrap(store.storedItem(original.id)); item.status = .completed; item.completedAt = stamp
            let event = TodoEvent(itemID: item.id, kind: .completed, occurredAt: stamp)
            try store.commit(item, event: event, clearDraft: true)
            XCTAssertEqual(try store.records(in: "event").count, 1)
            item = try XCTUnwrap(store.storedItem(item.id)); item.status = .active; item.completedAt = nil
            try store.commit(item, event: TodoEvent(itemID: item.id, kind: .completionUndone, occurredAt: stamp, relatedCompletionID: event.id), clearDraft: true)
        }
        XCTAssertTrue(try store.records(in: "event").isEmpty)
        XCTAssertTrue(try store.syncState()!.changes.flatMap(\.events).isEmpty)
        XCTAssertEqual(try store.syncState()!.changes.flatMap(\.writes).filter { $0.field == "lifecycle" }.count, 1)
    }

    @MainActor
    func testOfflineOldGenerationDetachesWithoutRetainingTheLifecycleChain() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let a = try TodoRepository(paths: AppPaths(root: folder.appendingPathComponent("a")), appVersion: "0.10.0")
        let b = try TodoRepository(paths: AppPaths(root: folder.appendingPathComponent("b")), appVersion: "0.10.0")
        let project = try a.createProject(name: "项目代次")
        try a.initializeSync(); try b.initializeSync()
        let ca = SyncCoordinator(), cb = SyncCoordinator(), dav = MemoryDAV(); ca.attach(a); cb.attach(b)
        _ = try await ca.exchange(using: dav); _ = try await cb.exchange(using: dav)
        let old = TodoItem(title: "离线旧代次新事项", projectID: project.id, createdAt: stamp)
        try b.commit(old, event: TodoEvent(itemID: old.id, kind: .created, occurredAt: stamp), clearDraft: true)
        _ = try a.archiveProject(id: project.id); _ = try a.restoreProject(id: project.id)
        _ = try await ca.exchange(using: dav); _ = try await cb.exchange(using: dav); _ = try await ca.exchange(using: dav)
        let detached = try XCTUnwrap(a.storedItem(old.id))
        XCTAssertNil(detached.projectID)
        XCTAssertTrue(detached.projectAssignments.contains { $0.previousProjectID == project.id && $0.reason == .generationExpired && $0.changedAt == nil })
        let fresh = TodoItem(title: "新代次事项", projectID: project.id, createdAt: stamp)
        try b.commit(fresh, event: TodoEvent(itemID: fresh.id, kind: .created, occurredAt: stamp), clearDraft: true)
        _ = try await cb.exchange(using: dav); _ = try await ca.exchange(using: dav)
        XCTAssertEqual(try a.storedItem(fresh.id)?.projectID, project.id)
        XCTAssertEqual(try a.syncState()!.changes.flatMap(\.writes).filter { $0.entity == SyncGraph.entity("project", project.id) && $0.field == "lifecycle" }.count, 1)
        _ = try BackupCodec.decode(BackupCodec.encode(a.archive()))
    }

    func testSameSequenceWithDifferentOperationCannotBeAcknowledged() throws {
        let writer = UUID(), item = TodoItem(title: "原始操作", createdAt: stamp)
        var state = SyncState(); state.current = CurrentSyncState()
        let change = try XCTUnwrap(SyncBuilder.capture(before: SyncContents(items: [], projects: [], events: []), after: SyncContents(items: [item], projects: [], events: []), state: state))
        let key = SyncGraph.entity("todo", item.id)
        let mutation = SyncMutation(entity: key, writerID: writer, sequence: 1, change: change)
        var record = SyncEntityRecord(libraryID: UUID(), entity: key, change: SyncChange(writerID: writer, date: stamp, writes: []))
        record = try SyncCurrent.merging(mutation, into: record)
        var clone = mutation; clone.id = UUID()
        XCTAssertThrowsError(try SyncCurrent.merging(clone, into: record))
        XCTAssertEqual(try SyncGraph([record.change]).projection().items.first?.title, item.title)
    }

    func testIndependentV3FixtureHasStableCrossPlatformDigest() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sync-v3-work.json")
        let intent = try SyncCodec.unwrap(SyncWorkIntent.self, Data(contentsOf: file))
        try intent.validate(library: intent.libraryID, owner: intent.mutation.writerID)
        XCTAssertEqual(intent.version, 3)
        let notes = try XCTUnwrap(intent.mutation.change.writes.first { $0.field == "notes" })
        XCTAssertEqual(try SyncCodec.decode(String.self, notes.value), "正文/第一行\n第二行 🚀")
        let record = try SyncCurrent.merging(intent.mutation, into: SyncEntityRecord(libraryID: intent.libraryID, entity: intent.mutation.entity,
            change: SyncChange(writerID: intent.mutation.writerID, date: stamp, writes: [])))
        XCTAssertEqual(try SyncGraph([record.change]).projection().items.first?.title, "跨端/事项")
    }

    @MainActor
    func testOnlyManagedHistoricalBackupsAreReplacedByLatest() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TodoRepository(paths: AppPaths(root: folder), appVersion: "0.10.0")
        var item = TodoItem(title: "最新恢复备份", createdAt: stamp)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: stamp), clearDraft: true)
        try await store.createAutomaticBackupNow()
        let old = try BackupCodec.encode(store.archive()), files = FileManager.default
        try old.write(to: store.paths.backups.appendingPathComponent("daily-2020-01-01.pindobackup"))
        try old.write(to: store.paths.backups.appendingPathComponent("before-restore.pindobackup"))
        try old.write(to: store.paths.backups.appendingPathComponent("my-export.pindobackup"))
        let snapshot = store.paths.backups.appendingPathComponent("before-upgrade-\(UUID())")
        try files.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try DatabaseSnapshot.copy(from: store.paths.store, to: snapshot.appendingPathComponent("PinDo.store"))
        try files.copyItem(at: store.paths.manifest, to: snapshot.appendingPathComponent("StoreInfo.json"))
        let incomplete = store.paths.backups.appendingPathComponent("before-upgrade-\(UUID())")
        try files.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try files.copyItem(at: store.paths.manifest, to: incomplete.appendingPathComponent("StoreInfo.json"))
        let empty = store.paths.backups.appendingPathComponent("before-upgrade-\(UUID())")
        try files.createDirectory(at: empty, withIntermediateDirectories: true)
        let protected = folder.appendingPathComponent("external-copy")
        try old.write(to: protected)
        try files.createSymbolicLink(at: store.paths.backups.appendingPathComponent("daily-2020-01-02.pindobackup"), withDestinationURL: protected)
        item.notes = "当前唯一恢复内容"
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: stamp), clearDraft: true)
        try await store.createAutomaticBackupNow()
        let remaining = Set(try files.contentsOfDirectory(atPath: store.paths.backups.path))
        let details = (try? files.contentsOfDirectory(atPath: snapshot.path)) ?? []
        XCTAssertEqual(remaining, ["recovery.latest.pindobackup", "my-export.pindobackup", "daily-2020-01-02.pindobackup"], "snapshot contents: \(details)")
        XCTAssertEqual(try Data(contentsOf: protected), old)
        let latest = try BackupCodec.decode(Data(contentsOf: store.paths.backups.appendingPathComponent("recovery.latest.pindobackup")))
        let saved = try JSONDecoder().decode(TodoItem.self, from: XCTUnwrap(latest.records.first { $0.bucket == "todo-active" }).payload)
        XCTAssertEqual(saved.notes, item.notes)
    }

    @MainActor
    func testFailedBackupReplacementKeepsLastVerifiedBackup() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TodoRepository(paths: AppPaths(root: folder), appVersion: "0.10.0")
        var item = TodoItem(title: "备份失败不能先删旧副本", createdAt: stamp)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: stamp), clearDraft: true)
        try await store.createAutomaticBackupNow()
        let latest = store.paths.backups.appendingPathComponent("recovery.latest.pindobackup"), old = try Data(contentsOf: latest)
        let historic = store.paths.backups.appendingPathComponent("daily-2020-01-01.pindobackup")
        try old.write(to: historic)
        item.notes = "新内容仍在数据库中"
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: stamp), clearDraft: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.paths.backups.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.paths.backups.path) }
        do { try await store.createAutomaticBackupNow(); XCTFail("Read-only destination unexpectedly replaced") } catch { }
        XCTAssertEqual(try Data(contentsOf: latest), old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: historic.path))
        XCTAssertEqual(try store.storedItem(item.id)?.notes, item.notes)
    }

    @MainActor
    func testUnverifiableWorkIsPreservedAndNeverReportedAsSynced() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TodoRepository(paths: AppPaths(root: folder), appVersion: "0.10.0")
        try store.initializeSync()
        let sync = SyncCoordinator(), dav = MemoryDAV(); sync.attach(store)
        _ = try await sync.exchange(using: dav)
        let success = try store.syncState()?.lastSuccess
        let bytes = Data("partial unverified bytes".utf8)
        let path = SyncWorkFile(owner: UUID(), data: bytes, kind: .payload).path
        await dav.overwrite(path, bytes)
        do { _ = try await sync.exchange(using: dav); XCTFail("Unverified work silently erased") } catch { }
        let remaining = try await dav.get(path)
        XCTAssertEqual(remaining.data, bytes)
        XCTAssertEqual(try store.syncState()?.lastSuccess, success)
    }

    @MainActor
    func testLocalV2PendingMetadataCanBeResetWithoutLosingContent() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TodoRepository(paths: AppPaths(root: folder), appVersion: "0.10.0")
        let item = TodoItem(title: "保留本机数据", notes: "旧版本/最新正文", createdAt: stamp)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: stamp), clearDraft: true)
        try store.initializeSync()
        let row = try XCTUnwrap(store.record(key: "sync-state"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: row.payload) as? [String: Any])
        var current = try XCTUnwrap(object["current"] as? [String: Any])
        current.removeValue(forKey: "protocolVersion")
        var outbox = try XCTUnwrap(current["outbox"] as? [String: [String: Any]])
        for key in Array(outbox.keys) { outbox[key]?.removeValue(forKey: "id") }
        current["outbox"] = outbox; object["current"] = current
        row.payload = try JSONSerialization.data(withJSONObject: object); try store.context.save()
        try store.prepareCompactStorage()
        XCTAssertEqual(try store.syncState()?.current?.protocolVersion, 3)
        XCTAssertNil(try store.syncState()?.libraryID)
        XCTAssertEqual(try store.syncState()?.pendingCount, 1)
        XCTAssertEqual(try store.storedItem(item.id)?.notes, item.notes)
        _ = try BackupCodec.decode(BackupCodec.encode(store.archive()))
    }

    @MainActor
    func testRepeatedOlderProjectSnapshotCannotReviveItsLifecycleOrAccumulateParents() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TodoRepository(paths: AppPaths(root: folder), appVersion: "0.10.0")
        let project = try store.createProject(name: "项目快照合并")
        try store.initializeSync()
        _ = try store.archiveProject(id: project.id)
        let archived = try store.archive()
        _ = try store.restoreProject(id: project.id)
        for _ in 0..<10 { try store.restore(archived) }
        XCTAssertEqual(try store.project(project.id).status, .active)
        let entity = SyncGraph.entity("project", project.id), state = try XCTUnwrap(store.syncState())
        XCTAssertEqual(state.changes.flatMap(\.writes).filter { $0.entity == entity && $0.field == "lifecycle" }.count, 1)
        XCTAssertEqual(state.current?.outbox[entity]?.change.writes.filter { $0.field == "lifecycle" }.count, 1)
        _ = try BackupCodec.decode(BackupCodec.encode(store.archive()))
    }

    func testAtomicFilesReuseOnePendingNameAfterInterruption() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("latest.json"), first = Data("first complete state".utf8), second = Data("second complete state".utf8)
        try StorageMaintenance.atomicWrite(first, to: destination)
        try Data("partial interrupted write".utf8).write(to: destination.appendingPathExtension("pending"))
        try StorageMaintenance.atomicWrite(second, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["latest.json"])
    }

    @MainActor
    func testInterruptedInitialManifestCanBeRecoveredWithoutCreatingAnotherIdentity() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paths = AppPaths(root: folder)
        let manifest = StoreManifest(storeID: UUID(), createdAt: stamp, lastAppVersion: "0.10.0", migrationPending: true)
        try JSONEncoder().encode(manifest).write(to: paths.manifest.appendingPathExtension("pending"))
        let store = try TodoRepository(paths: paths, appVersion: "0.10.0")
        XCTAssertTrue(try store.loadActiveItems().isEmpty)
        let recovered = try JSONDecoder().decode(StoreManifest.self, from: Data(contentsOf: paths.manifest))
        XCTAssertEqual(recovered.storeID, manifest.storeID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.manifest.appendingPathExtension("pending").path))
    }

    @MainActor
    func testPendingNewerManifestStillBlocksDowngrade() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let paths = AppPaths(root: folder)
        var store: TodoRepository? = try TodoRepository(paths: paths, appVersion: "0.10.0")
        let item = TodoItem(title: "升级中断仍保护原数据", createdAt: stamp)
        try store!.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: stamp), clearDraft: true)
        store = nil
        var manifest = try JSONDecoder().decode(StoreManifest.self, from: Data(contentsOf: paths.manifest))
        manifest.lastAppVersion = "0.11.0"
        try JSONEncoder().encode(manifest).write(to: paths.manifest.appendingPathExtension("pending"))
        XCTAssertThrowsError(try TodoRepository(paths: paths, appVersion: "0.10.0"))
        store = try TodoRepository(paths: paths, appVersion: "0.11.0")
        XCTAssertEqual(try store!.storedItem(item.id)?.title, item.title)
        store = nil
    }

    @MainActor
    func testIncompleteManifestMarkerCannotReplaceAValidManifest() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let paths = AppPaths(root: folder)
        var store: TodoRepository? = try TodoRepository(paths: paths, appVersion: "0.10.0")
        let item = TodoItem(title: "不完整标记不是新库", createdAt: stamp)
        try store!.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: stamp), clearDraft: true)
        store = nil
        try Data("{partial".utf8).write(to: paths.manifest.appendingPathExtension("pending"))
        store = try TodoRepository(paths: paths, appVersion: "0.10.0")
        XCTAssertEqual(try store!.storedItem(item.id)?.title, item.title)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.manifest.appendingPathExtension("pending").path))
        store = nil
    }

    @MainActor
    func testVerifiedProbeCanBeCleanedAfterClockMovesBackward() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TodoRepository(paths: AppPaths(root: folder), appVersion: "0.10.0")
        try store.initializeSync()
        let sync = SyncCoordinator(), dav = MemoryDAV(); sync.attach(store)
        _ = try await sync.exchange(using: dav)
        let owner = UUID(), path = "_work/" + owner.uuidString.lowercased() + ".probe-a.json"
        let marker = SyncProbeMarker(owner: owner, nonce: UUID(), phase: "a", createdAt: Date.now.addingTimeInterval(86400))
        await dav.overwrite(path, try SyncCodec.encode(marker))
        _ = try await sync.exchange(using: dav)
        let cleaned = try await dav.get(path); XCTAssertEqual(cleaned.status, 404)
    }

    func testWorkCleanupRejectsBusinessPathsAndCorruptContent() async throws {
        let dav = MemoryDAV(), bytes = Data("confirmed input".utf8), damaged = Data("damaged input".utf8)
        await dav.setUnsafeDelete()
        let business = "records/todo-" + UUID().uuidString.lowercased() + ".json"
        await dav.overwrite(business, bytes)
        do { _ = try await dav.deleteWorkFile(business, response: dav.get(business)); XCTFail("Business path accepted") } catch { }
        let path = SyncWorkFile(owner: UUID(), data: bytes, kind: .payload).path
        await dav.overwrite(path, damaged)
        do { _ = try await dav.deleteWorkFile(path, response: dav.get(path)); XCTFail("Digest mismatch accepted") } catch { }
        let keptBusiness = try await dav.get(business), keptDamaged = try await dav.get(path)
        XCTAssertEqual(keptBusiness.data, bytes); XCTAssertEqual(keptDamaged.data, damaged)
    }

    @MainActor
    func testConditionalPutServerWorksWhenDeleteIgnoresIfMatch() async throws {
        BootstrapDAVProtocol.server.reset(unsafeDelete: true)
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TodoRepository(paths: AppPaths(root: folder), appVersion: "0.10.1")
        let item = TodoItem(title: "条件 PUT 的兼容路径", createdAt: stamp)
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: stamp), clearDraft: true)
        try store.initializeSync()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BootstrapDAVProtocol.self]
        let client = try WebDAVClient(connection: SyncConnection(server: "https://bootstrap.invalid/dav/", directory: "immutable", username: "test"), password: "test-only", configuration: config, installationID: store.syncState()!.writerID)
        try await client.prepareRootHierarchy()
        let mode = try await client.probe(); XCTAssertEqual(mode, .conditionalPut)
        let sync = SyncCoordinator(); sync.attach(store)
        _ = try await sync.exchange(using: client)
        XCTAssertEqual(try store.syncState()?.pendingCount, 0)
        XCTAssertEqual(BootstrapDAVProtocol.server.filePaths.count, 3)
        XCTAssertFalse(BootstrapDAVProtocol.server.filePaths.contains { $0.contains("_work/") })
    }
}

final class ScheduleSyncTests: XCTestCase {
    @MainActor
    func testLegacyCloudUpgradesInPlaceAndConcurrentSchedulesStayAtomic() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-schedule-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try TodoRepository(paths: AppPaths(root: folder.appendingPathComponent("a")), appVersion: "1.1.0")
        let b = try TodoRepository(paths: AppPaths(root: folder.appendingPathComponent("b")), appVersion: "1.1.0")
        let item = TodoItem(title: "并发安排", dueAt: now.addingTimeInterval(7200), createdAt: now)
        try a.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true)
        try a.initializeSync(); try b.initializeSync()
        let dav = MemoryDAV(), ca = SyncCoordinator(), cb = SyncCoordinator()
        ca.attach(a); cb.attach(b)
        let identity = UUID()
        try await dav.create("library.json", data: SyncCodec.wrap(SyncLibrary(version: 3, id: identity)))
        _ = try await ca.exchange(using: dav); _ = try await cb.exchange(using: dav)
        let root = try SyncCodec.unwrap(SyncLibrary.self, await dav.get("library.json").data)
        XCTAssertEqual(root.id, identity); XCTAssertEqual(root.version, 4)
        var left = try XCTUnwrap(a.storedItem(item.id)), right = try XCTUnwrap(b.storedItem(item.id))
        left.plannedStartAt = now.addingTimeInterval(3600)
        right.dueAt = now.addingTimeInterval(1800); right.plannedStartAt = now
        try a.commit(left, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: now), clearDraft: true)
        try b.commit(right, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: now), clearDraft: true)
        _ = try await ca.exchange(using: dav); _ = try await cb.exchange(using: dav); _ = try await ca.exchange(using: dav)
        let graph = try SyncGraph(XCTUnwrap(a.syncState()).changes)
        let conflict = try XCTUnwrap(graph.conflicts().first { $0.field == "deadline" })
        let options = try conflict.candidates.map { try TodoSchedule.decodeSync($0.value) }
        XCTAssertEqual(Set(options.map { $0.startAt! }), Set([left.plannedStartAt!, right.plannedStartAt!]))
        XCTAssertTrue(options.contains(left.schedule)); XCTAssertTrue(options.contains(right.schedule))
        XCTAssertTrue(try XCTUnwrap(a.storedItem(item.id)).schedule.isValid)
        try a.resolveSyncConflict(conflict, candidate: XCTUnwrap(conflict.candidates.first { (try? TodoSchedule.decodeSync($0.value)) == left.schedule }))
        _ = try await ca.exchange(using: dav); _ = try await cb.exchange(using: dav)
        XCTAssertEqual(try b.storedItem(item.id)?.schedule, left.schedule)
        var complete = try XCTUnwrap(a.storedItem(item.id)); complete.status = .completed; complete.completedAt = now.addingTimeInterval(5400)
        try a.commit(complete, event: TodoEvent(itemID: item.id, kind: .completed, occurredAt: complete.completedAt!), clearDraft: true)
        _ = try await ca.exchange(using: dav); _ = try await cb.exchange(using: dav)
        XCTAssertEqual(try b.storedItem(item.id)?.completionSchedule?.startAt, left.plannedStartAt)
        let puts = await dav.puts
        _ = try await ca.exchange(using: dav)
        let after = await dav.puts
        XCTAssertEqual(after, puts)
        let paths = await dav.files.keys
        XCTAssertFalse(paths.contains { $0.hasPrefix("_work/") })
        _ = try BackupCodec.decode(BackupCodec.encode(a.archive()))
    }
}
