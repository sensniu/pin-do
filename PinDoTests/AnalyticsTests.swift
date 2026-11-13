import XCTest

final class AnalyticsTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var now: Date { date("2026-11-13T15:00:00+08:00") }
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return value }
    private func item(_ title: String, created: String, status: TodoStatus = .active, ended: String? = nil, due: Date? = nil, project: UUID? = nil) -> TodoItem {
        var value = TodoItem(title: title, dueAt: due, projectID: project, createdAt: date(created))
        value.status = status
        if status == .completed { value.completedAt = ended.map(date) }
        if status == .abandoned { value.abandonedAt = ended.map(date) }
        return value
    }
    private func calculate(_ input: AnalyticsInput, scope: BoardScope = .all, range: AnalyticsRange = .recent(7)) throws -> AnalyticsResult {
        try AnalyticsEngine.calculate(input, scope: scope, range: range, now: now, calendar: calendar)
    }
    private func sample() -> AnalyticsInput {
        let p = Project(name: "甲", now: date("2026-10-01T00:00:00+08:00"))
        var q = Project(name: "乙", now: p.createdAt); q.status = .archived; q.archivedAt = now
        let values = [
            item("A", created: "2026-11-01T09:00:00+08:00", due: date("2026-11-12T12:00:00+08:00"), project: p.id),
            item("B", created: "2026-11-12T09:00:00+08:00", project: p.id),
            item("C", created: "2026-11-02T09:00:00+08:00", status: .completed, ended: "2026-11-10T10:00:00+08:00", project: p.id),
            item("D", created: "2026-11-08T09:00:00+08:00", status: .abandoned, ended: "2026-11-09T10:00:00+08:00", project: q.id),
            item("E", created: "2026-11-13T09:00:00+08:00", status: .completed, ended: "2026-11-13T14:00:00+08:00", project: q.id),
            item("F", created: "2026-11-13T09:00:00+08:00", due: now),
            item("G", created: "2026-11-10T09:00:00+08:00", status: .conflicted, project: p.id),
            item("H", created: "2026-11-11T09:00:00+08:00", due: date("2026-11-10T12:00:00+08:00"))
        ]
        return AnalyticsInput(items: values, projects: [p,q], issues: [values[7].id: ["membership", "deadline"], values[6].id: ["lifecycle"]])
    }
    func testDocumentedEightItemExampleAndAllReconciliations() throws {
        let result = try calculate(sample())
        XCTAssertEqual(result.active.count, 4); XCTAssertEqual(result.overdue.count, 1); XCTAssertEqual(result.completed.count, 2)
        XCTAssertEqual(result.trend.reduce(0) { $0 + $1.created.count }, 6)
        XCTAssertEqual(result.trend.reduce(0) { $0 + $1.completed.count }, result.completed.count)
        XCTAssertEqual(result.activeProjects.reduce(0) { $0 + $1.items.count }, result.active.count)
        XCTAssertEqual(result.completedProjects.reduce(0) { $0 + $1.items.count }, result.completed.count)
        XCTAssertEqual(result.ages.reduce(0) { $0 + $1.items.count }, result.active.count)
        XCTAssertEqual(result.ages.first { $0.age == .recent }?.items.count, 3)
        XCTAssertEqual(result.ages.first { $0.age == .fortnight }?.items.count, 1)
        XCTAssertEqual(result.statusIssues.count, 1); XCTAssertEqual(result.deadlineIssues.count, 1)
        XCTAssertEqual(result.records(for: .abandoned).map(\.title), ["D"])
    }
    func testEveryDetailUsesExactlyTheSummarizedIDs() throws {
        let result = try calculate(sample())
        var details: [AnalyticsDetail] = [.active,.overdue,.completed,.abandoned,.statusIssues,.deadlineIssues,.membershipIssues,.timeIssues]
        details += result.trend.flatMap { [.createdBucket($0.id), .completedBucket($0.id)] }
        details += result.ages.map { .age($0.age) }
        details += result.activeProjects.map { .project($0.key,.active) }
        details += result.completedProjects.map { .project($0.key,.completed) }
        for detail in details { XCTAssertEqual(Set(result.records(for: detail).map(\.id)), Set(result.ids(for: detail))) }
    }
    func testCurrentCountsDoNotFollowHistoricalDateFilter() throws {
        let input = sample(), first = try calculate(input), second = try calculate(input, range: .recent(30))
        XCTAssertEqual(first.active, second.active); XCTAssertEqual(first.overdue, second.overdue)
        XCTAssertEqual(first.ages.map { $0.items.count }, second.ages.map { $0.items.count })
    }
    func testCompletionDoesNotRequireCreationInTheSamePeriod() throws {
        let input = sample(), result = try calculate(input)
        let old = input.items.first { $0.title == "C" }!
        XCTAssertTrue(result.completed.contains(old.id)); XCTAssertFalse(result.trend.flatMap(\.created).contains(old.id))
        XCTAssertTrue(result.trend.flatMap(\.created).contains(input.items.first { $0.title == "D" }!.id))
    }
    func testDateRangeIsInclusiveForSelectedDaysAndHalfOpenForInstants() throws {
        let start = date("2026-11-12T00:00:00+08:00"), end = date("2026-11-13T00:00:00+08:00")
        let a = TodoItem(title: "start", createdAt: start), b = TodoItem(title: "before", createdAt: start.addingTimeInterval(-0.001)), c = TodoItem(title: "end", createdAt: end)
        let result = try calculate(AnalyticsInput(items: [a,b,c], projects: []), range: .custom(start,start))
        XCTAssertEqual(result.interval.start, start); XCTAssertEqual(result.interval.end,end)
        XCTAssertEqual(result.trend.flatMap(\.created), [a.id])
    }
    func testDeadlineMustBeStrictlyEarlierThanTheCapturedInstant() throws {
        let values = [TodoItem(title: "equal", dueAt: now, createdAt: now), TodoItem(title: "past", dueAt: now.addingTimeInterval(-0.001), createdAt: now), TodoItem(title: "none", createdAt: now)]
        let result = try calculate(AnalyticsInput(items: values, projects: []))
        XCTAssertEqual(result.overdue, [values[1].id]); XCTAssertEqual(result.nextRefresh, now.addingTimeInterval(0.1))
    }
    func testMembershipConflictIsNotUnassigned() throws {
        let input = sample(), all = try calculate(input), unassigned = try calculate(input, scope: .unassigned)
        XCTAssertEqual(all.activeProjects.first { $0.key == .pending }?.items.count, 1)
        XCTAssertEqual(all.activeProjects.first { $0.key == .unassigned }?.items.count, 1)
        XCTAssertEqual(unassigned.active.count, 1); XCTAssertEqual(unassigned.records(for: .active).first?.title, "F")
    }
    func testDeadlineConflictDoesNotAffectOtherCounts() throws {
        var input = sample()
        let first = try calculate(input)
        input.issues[input.items[7].id]?.remove("deadline")
        let next = try calculate(input)
        XCTAssertEqual(first.active,next.active); XCTAssertEqual(first.completed,next.completed)
        XCTAssertEqual(next.overdue.count,first.overdue.count+1)
    }
    func testTextConflictsDoNotSuppressValidCompletionOrCreation() throws {
        var input = sample(); input.issues[input.items[4].id] = ["notes","title"]
        let result = try calculate(input)
        XCTAssertEqual(result.completed.count, 2); XCTAssertEqual(result.trend.flatMap(\.created).count, 6)
    }
    func testCompletionUndoRecalculatesCurrentResultWithoutRecountingCreation() throws {
        var input = sample(); let first = try calculate(input)
        input.items[4].status = .active; input.items[4].completedAt = nil
        let next = try calculate(input)
        XCTAssertEqual(next.completed.count, first.completed.count-1); XCTAssertEqual(next.active.count,first.active.count+1)
        XCTAssertEqual(next.trend.flatMap(\.created).count,first.trend.flatMap(\.created).count)
        // If another independent completion remains valid, the business projection stays completed.
        input.items[4].status = .completed; input.items[4].completedAt = now.addingTimeInterval(-20)
        XCTAssertEqual(try calculate(input).completed.count,first.completed.count)
    }
    func testArchivedAndDeletedProjectResultsKeepStableIdentity() throws {
        var input = sample(); let before = try calculate(input)
        input.projects[1].name = input.projects[0].name
        input.projects[1].status = .deleted; input.projects[1].deletedAt = now
        let after = try calculate(input)
        XCTAssertEqual(after.completed.count,before.completed.count); XCTAssertEqual(after.completedProjects.count,2)
        XCTAssertTrue(after.projectName(.project(input.projects[1].id)).contains("已删除"))
        XCTAssertNotEqual(after.projectName(.project(input.projects[0].id)),after.projectName(.project(input.projects[1].id)))
    }
    func testProjectTransferUsesCurrentMembershipWithoutDoubleCountingSource() throws {
        var input = sample(); let total = try calculate(input).trend.flatMap(\.created).count
        let moved = input.items[1].id
        input.items[1].projectID = input.projects[1].id
        XCTAssertEqual(try calculate(input).trend.flatMap(\.created).count,total)
        XCTAssertFalse(try calculate(input,scope:.project(input.projects[0].id)).active.contains(moved))
        XCTAssertTrue(try calculate(input,scope:.project(input.projects[1].id)).active.contains(moved))
    }
    func testWaitingBucketsUseAllBoundariesExactlyOnce() throws {
        let days = [0,2,3,7,8,14,15,30,31]
        let items = days.map { TodoItem(title: "\($0)", createdAt: calendar.date(byAdding:.day,value: -$0,to: now)!) }
        let result = try calculate(AnalyticsInput(items:items,projects:[]))
        XCTAssertEqual(result.ages.map { $0.items.count },[2,2,2,2,1])
        XCTAssertEqual(Set(result.ages.flatMap(\.items)).count,items.count)
    }
    func testWaitingUsesCalendarDateRatherThanFullTwentyFourHours() throws {
        let created = date("2026-11-12T23:59:00+08:00"), current = date("2026-11-13T00:01:00+08:00")
        let value = TodoItem(title:"cross midnight",createdAt:created)
        XCTAssertEqual(calendar.dateComponents([.day],from:calendar.startOfDay(for:created),to:calendar.startOfDay(for:current)).day,1)
        XCTAssertEqual(AnalyticsAge.classify(value,now:current,calendar:calendar),.recent)
    }
    func testFutureTimestampsStayVisibleAsUnknownAndNeverBecomeZeroDayWork() throws {
        var a = TodoItem(title:"future created",createdAt:now.addingTimeInterval(60))
        var b = TodoItem(title:"future completion",createdAt:now.addingTimeInterval(-60)); b.status = .completed; b.completedAt = now.addingTimeInterval(120)
        a.dueAt = nil
        let result = try calculate(AnalyticsInput(items:[a,b],projects:[]))
        XCTAssertEqual(result.active.count,1); XCTAssertEqual(result.completed.count,0)
        XCTAssertEqual(result.ages.first { $0.age == .unknown }?.items,[a.id]); XCTAssertEqual(result.timeIssues.count,2)
        XCTAssertEqual(result.nextRefresh,now.addingTimeInterval(60.1))
    }
    func testDayIntervalsRespectSpringAndAutumnDST() throws {
        var cal = Calendar(identifier:.gregorian); cal.timeZone = TimeZone(identifier:"America/Los_Angeles")!
        let spring = date("2026-03-08T18:00:00-07:00"), autumn = date("2026-11-01T18:00:00-08:00")
        XCTAssertEqual(try AnalyticsRange.recent(1).interval(now:spring,calendar:cal).duration,23*3600)
        XCTAssertEqual(try AnalyticsRange.recent(1).interval(now:autumn,calendar:cal).duration,25*3600)
    }
    func testThirtyOneDaysUseDailyAndThirtyTwoUseClippedNaturalWeeks() throws {
        XCTAssertFalse(try calculate(sample(),range:.recent(31)).weekly)
        let result = try calculate(sample(),range:.recent(32))
        XCTAssertTrue(result.weekly); XCTAssertEqual(result.trend.first?.interval.start,result.interval.start)
        XCTAssertEqual(result.trend.last?.interval.end,result.interval.end)
        for bucket in result.trend.dropFirst() { XCTAssertEqual(result.calendar.component(.weekday,from:bucket.interval.start),2) }
        XCTAssertEqual(result.trend.reduce(0) { $0+$1.completed.count },result.completed.count)
    }
    func testIdenticalDuplicateInputNeverMultipliesItems() throws {
        let value = TodoItem(title:"once",createdAt:now)
        let result = try calculate(AnalyticsInput(items:[value,value,value],projects:[]))
        XCTAssertEqual(result.active.count,1); XCTAssertEqual(result.trend.flatMap(\.created).count,1)
    }
    func testDifferentRecordsWithSameIdentityAreRejected() throws {
        let a = TodoItem(title:"first",createdAt:now); var b = a; b.title = "different"
        XCTAssertThrowsError(try calculate(AnalyticsInput(items:[a,b],projects:[])))
    }
    func testEmptyDataHasRealZerosAndNoFakeRecords() throws {
        let result = try calculate(AnalyticsInput(items:[],projects:[]))
        XCTAssertEqual(result.active.count,0); XCTAssertEqual(result.completed.count,0); XCTAssertEqual(result.overdue.count,0)
        XCTAssertTrue(result.records(for:.completed).isEmpty); XCTAssertEqual(result.trend.count,7)
    }
    func testInvalidAndFutureRangesAreRejected() throws {
        XCTAssertThrowsError(try calculate(sample(),range:.custom(now,now.addingTimeInterval(-86400))))
        XCTAssertThrowsError(try calculate(sample(),range:.custom(now,now.addingTimeInterval(86400))))
        XCTAssertThrowsError(try calculate(sample(),range:.recent(0)))
    }
    @MainActor
    func testBackgroundReaderIncludesEndedItemsWithoutWritingOrEnqueuingSync() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-analytics-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try TodoRepository(paths:AppPaths(root:root),appVersion:"0.11.0")
        let a = TodoItem(title:"active",createdAt:now)
        var b = TodoItem(title:"completed",createdAt:now)
        try store.commit(a,event:TodoEvent(itemID:a.id,kind:.created,occurredAt:now),clearDraft:true)
        try store.commit(b,event:TodoEvent(itemID:b.id,kind:.created,occurredAt:now),clearDraft:true)
        b.status = .completed; b.completedAt = now
        try store.commit(b,event:TodoEvent(itemID:b.id,kind:.completed,occurredAt:now),clearDraft:true)
        try store.initializeSync()
        let pending = try store.syncState()?.pendingCount
        var writes = 0; store.onContentsChange = { writes += 1 }
        let input = try await store.analyticsInput()
        XCTAssertEqual(input.items.count,2); XCTAssertEqual(try store.loadActiveItems().count,1)
        XCTAssertEqual(try store.syncState()?.pendingCount,pending); XCTAssertEqual(writes,0)
        let count = try AnalyticsEngine.calculate(input,scope:.all,range:.recent(7),now:now,calendar:calendar)
        XCTAssertEqual(count.completed.count,1)
    }
    @MainActor
    final class DeferredInput {
        var requests = 0
        var waiting: [Int: CheckedContinuation<AnalyticsInput,Never>] = [:]
        func read() async -> AnalyticsInput {
            requests += 1; let key = requests
            return await withCheckedContinuation { waiting[key] = $0 }
        }
        func finish(_ key:Int,_ input:AnalyticsInput) { waiting.removeValue(forKey:key)?.resume(returning:input) }
        func finishAll(_ input:AnalyticsInput) { let values = waiting.values; waiting = [:]; for value in values { value.resume(returning:input) } }
    }
    @MainActor
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(for:.milliseconds(20)) }
        XCTFail("Condition did not become true")
    }
    @MainActor
    func testSlowOldComputationCannotOverrideNewProjectSelection() async throws {
        let source = DeferredInput(), model = AnalyticsModel(), project = Project(name:"selected")
        let input = AnalyticsInput(items:[TodoItem(title:"selected",projectID:project.id),TodoItem(title:"other")],projects:[project])
        defer { source.finishAll(input); model.deactivate() }
        model.configure { await source.read() }; model.activate(scope:.all)
        try await eventually { source.requests == 1 }
        model.scope = .project(project.id)
        try await eventually { source.requests == 2 }
        source.finish(2,input)
        try await eventually { model.result != nil }
        XCTAssertEqual(model.result?.active.count,1)
        source.finish(1,input)
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(model.result?.active.count,1)
    }
    @MainActor
    func testInactiveOverviewDoesNotReadFullHistoryAndErrorsAreNotZeros() async throws {
        let model = AnalyticsModel(); var reads = 0
        model.configure { reads += 1; throw AnalyticsFailure.inconsistentData }
        model.invalidate(); try await Task.sleep(for:.milliseconds(150)); XCTAssertEqual(reads,0)
        model.activate(scope:.all)
        try await eventually { model.error != nil }
        XCTAssertNil(model.result); XCTAssertEqual(reads,1)
        model.deactivate(); model.invalidate(); try await Task.sleep(for:.milliseconds(150)); XCTAssertEqual(reads,1)
    }

    @MainActor
    func testActualSyncConflictsAreReadAndClassifiedWithoutTreatingNilAsUnassigned() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-analytics-conflicts-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let a = try TodoRepository(paths:AppPaths(root:root.appendingPathComponent("a")),appVersion:"0.11.0")
        let b = try TodoRepository(paths:AppPaths(root:root.appendingPathComponent("b")),appVersion:"0.11.0")
        let first = try a.createProject(name:"first"), second = try a.createProject(name:"second")
        let value = TodoItem(title:"concurrent fields",dueAt:now.addingTimeInterval(3600),projectID:first.id,createdAt:now.addingTimeInterval(-86400))
        try a.commit(value,event:TodoEvent(itemID:value.id,kind:.created,occurredAt:value.createdAt),clearDraft:true)
        try a.initializeSync(); try b.initializeSync()
        let ca = SyncCoordinator(), cb = SyncCoordinator(), dav = MemoryDAV(); ca.attach(a); cb.attach(b)
        _ = try await ca.exchange(using:dav); _ = try await cb.exchange(using:dav)
        var left = try XCTUnwrap(a.storedItem(value.id)); left.dueAt = now.addingTimeInterval(-86400); left.projectID = second.id
        var right = try XCTUnwrap(b.storedItem(value.id)); right.dueAt = nil; right.projectID = nil
        try a.commit(left,event:TodoEvent(itemID:left.id,kind:.edited,occurredAt:now),clearDraft:true)
        try b.commit(right,event:TodoEvent(itemID:right.id,kind:.edited,occurredAt:now),clearDraft:true)
        _ = try await ca.exchange(using:dav); _ = try await cb.exchange(using:dav); _ = try await ca.exchange(using:dav)
        let input = try await a.analyticsInput()
        XCTAssertTrue(input.issues[value.id,default:[]].contains("deadline"))
        XCTAssertTrue(input.issues[value.id,default:[]].contains("membership"))
        let result = try calculate(input)
        XCTAssertEqual(result.active.count,1); XCTAssertEqual(result.overdue.count,0)
        XCTAssertEqual(result.activeProjects.map(\.key),[.pending])
        XCTAssertTrue(try calculate(input,scope:.unassigned).active.isEmpty)
    }

    @MainActor
    func testUnchangedRefreshAndFilterChangesReuseMemorySnapshotUntilInvalidated() async throws {
        let model = AnalyticsModel(); var reads = 0
        let input = AnalyticsInput(items:[TodoItem(title:"cached")],projects:[])
        model.configure { reads += 1; return input }; model.activate(scope:.all)
        defer { model.deactivate() }
        try await eventually { model.result != nil && !model.loading }
        model.refresh(); try await eventually { !model.loading }
        XCTAssertEqual(reads,1)
        model.preset = .week; try await eventually { model.result != nil && !model.loading }
        XCTAssertEqual(reads,1)
        model.invalidate(); try await eventually { !model.loading }
        XCTAssertEqual(reads,2)
        let revision = model.selectionRevision
        model.select(.completed); model.select(.completed)
        XCTAssertEqual(model.selectionRevision,revision+2)
    }

    func testTenThousandItemsReconcileWithoutEventHistory() throws {
        let values = (0..<10000).map { index -> TodoItem in
            var item = TodoItem(title:"item \(index)",dueAt:now.addingTimeInterval(-3600),createdAt:now.addingTimeInterval(-90*86400+Double(index)))
            if index.isMultiple(of:2) { item.status = .completed; item.completedAt = now.addingTimeInterval(-Double(index)) }
            return item
        }
        let result = try calculate(AnalyticsInput(items:values,projects:[]),range:.recent(90))
        XCTAssertEqual(result.active.count,5000); XCTAssertEqual(result.completed.count,5000); XCTAssertEqual(result.overdue.count,5000)
        XCTAssertEqual(result.trend.flatMap(\.completed).count,5000)
        XCTAssertEqual(result.activeProjects.flatMap(\.items).count,5000)
        XCTAssertEqual(result.ages.flatMap(\.items).count,5000)
        XCTAssertEqual(result.review.days.flatMap(\.items).count,5000)
        XCTAssertEqual(result.review.durations.count,5000)
        XCTAssertEqual(result.review.importance.flatMap(\.items).count,5000)
    }

    private func completion(seconds: TimeInterval, end: Date? = nil) -> TodoItem {
        let end = end ?? now
        var item = TodoItem(title: "elapsed \(seconds)", createdAt: end.addingTimeInterval(-seconds))
        item.status = .completed; item.completedAt = end
        return item
    }

    func testReviewDailyCalendarReconcilesEvenWhenTrendIsWeekly() throws {
        let result = try calculate(sample(), range: .recent(90))
        XCTAssertTrue(result.weekly); XCTAssertEqual(result.review.days.count,90)
        XCTAssertEqual(Set(result.review.days.flatMap(\.items)),Set(result.completed))
        XCTAssertEqual(result.review.days.flatMap(\.items).count,result.completed.count)
        XCTAssertEqual(result.review.days.last?.date,calendar.startOfDay(for:now))
        XCTAssertEqual(result.review.days.first?.date,result.interval.start)
        XCTAssertEqual(result.review.heatmapThresholds,[1,3,6,Int.max])
    }
    func testCompletionCalendarUsesLocalDayAndExcludesFutureCompletions() throws {
        let before = completion(seconds:60,end:date("2026-11-12T23:59:00+08:00"))
        let after = completion(seconds:60,end:date("2026-11-13T00:01:00+08:00"))
        let future = completion(seconds:60,end:now.addingTimeInterval(1))
        let input = AnalyticsInput(items:[before,after,future],projects:[])
        let result = try calculate(input)
        XCTAssertEqual(result.ids(for:.completionDay(calendar.startOfDay(for:before.completedAt!))),[before.id])
        XCTAssertEqual(result.ids(for:.completionDay(calendar.startOfDay(for:after.completedAt!))),[after.id])
        XCTAssertEqual(result.review.days.flatMap(\.items).count,2)
        var utc = calendar; utc.timeZone = TimeZone(secondsFromGMT:0)!
        let other = try AnalyticsEngine.calculate(input,scope:.all,range:.recent(7),now:now,calendar:utc)
        XCTAssertEqual(other.review.days.first { $0.items.count == 2 }?.items.count,2)
    }
    func testCalendarCustomRangeIsClippedAndDuplicateIDsCountOnce() throws {
        let a = completion(seconds:0,end:date("2026-11-10T00:00:00+08:00"))
        let b = completion(seconds:0,end:date("2026-11-11T00:00:00+08:00"))
        let result = try calculate(AnalyticsInput(items:[a,a,b],projects:[]),range:.custom(a.completedAt!,a.completedAt!))
        XCTAssertEqual(result.review.days.count,1); XCTAssertEqual(result.review.days[0].items,[a.id])
        XCTAssertEqual(result.review.durations.count,1)
    }
    func testLifetimeBucketsUseActualSecondsAndEveryBoundaryExactlyOnce() throws {
        let seconds: [Double] = [0,86399,86400,3*86400-1,3*86400,7*86400-1,7*86400,14*86400-1,14*86400,30*86400-1,30*86400]
        let result = try calculate(AnalyticsInput(items:seconds.map { completion(seconds:$0) },projects:[]))
        XCTAssertEqual(result.review.lifetimes.map { $0.items.count },[2,2,2,2,2,1])
        XCTAssertEqual(Set(result.review.lifetimes.flatMap(\.items)),Set(result.completed))
        XCTAssertEqual(result.review.durations.count,seconds.count)
    }
    func testLifetimeMedianOddEvenAndRecomputedAcrossProjects() throws {
        let p = Project(name:"one"),q = Project(name:"two")
        var items = [completion(seconds:1),completion(seconds:2),completion(seconds:100),completion(seconds:200)]
        items[0].projectID = p.id
        for index in 1..<items.count { items[index].projectID = q.id }
        let input = AnalyticsInput(items:items,projects:[p,q])
        XCTAssertEqual(try calculate(input).review.medianLifetime,51)
        XCTAssertEqual(try calculate(input,scope:.project(p.id)).review.medianLifetime,1)
        XCTAssertEqual(try calculate(input,scope:.project(q.id)).review.medianLifetime,100)
    }
    func testLifetimeMissingSamplesAreNotZeroButRealZeroIsValid() throws {
        let empty = try calculate(AnalyticsInput(items:[],projects:[]))
        XCTAssertNil(empty.review.medianLifetime); XCTAssertEqual(empty.review.heatmapThresholds,[1,3,6,Int.max])
        XCTAssertEqual(empty.review.importance.map { $0.items.count },[0,0,0])
        let zero = try calculate(AnalyticsInput(items:[completion(seconds:0)],projects:[]))
        XCTAssertEqual(zero.review.medianLifetime,0); XCTAssertEqual(AnalyticsReview.durationLabel(0),"0分钟")
        XCTAssertEqual(AnalyticsReview.durationLabel(1),"不足1分钟")
    }
    func testNegativeLifetimeIsVisibleButNotClampedToZero() throws {
        let invalid = completion(seconds:-60,end:now.addingTimeInterval(-120))
        let valid = completion(seconds:60)
        let result = try calculate(AnalyticsInput(items:[invalid,valid],projects:[]))
        XCTAssertEqual(result.completed.count,2); XCTAssertEqual(result.review.days.flatMap(\.items).count,2)
        XCTAssertEqual(result.review.durations.count,1); XCTAssertEqual(result.review.medianLifetime,60)
        XCTAssertEqual(result.review.lifetimeIssues,[invalid.id]); XCTAssertTrue(result.timeIssues.contains(invalid.id))
        XCTAssertEqual(result.records(for:.lifetimeIssues).map(\.id),[invalid.id])
    }
    func testLifetimeUsesElapsedTimeAcrossDSTAndCalendarStillHasDailyCells() throws {
        var cal = calendar; cal.timeZone = TimeZone(identifier:"America/Los_Angeles")!
        let examples = [("2026-03-08T00:00:00-08:00","2026-03-09T00:00:00-07:00",23.0,AnalyticsLifetime.day),
                        ("2026-11-01T00:00:00-07:00","2026-11-02T00:00:00-08:00",25.0,AnalyticsLifetime.threeDays)]
        for (start,end,hours,band) in examples {
            let value = completion(seconds:date(end).timeIntervalSince(date(start)),end:date(end))
            let result = try AnalyticsEngine.calculate(AnalyticsInput(items:[value],projects:[]),scope:.all,range:.recent(3),now:date(end),calendar:cal)
            XCTAssertEqual(result.review.durations[value.id],hours*3600)
            XCTAssertEqual(result.ids(for:.lifetime(band)),[value.id]); XCTAssertEqual(result.review.days.count,3)
        }
    }
    func testCompletionUndoUpdatesCalendarLifetimeAndImportanceTogether() throws {
        var value = completion(seconds:3600)
        let before = try calculate(AnalyticsInput(items:[value],projects:[]))
        value.status = .active; value.completedAt = nil
        let after = try calculate(AnalyticsInput(items:[value],projects:[]))
        XCTAssertEqual(before.review.days.flatMap(\.items).count,1)
        XCTAssertTrue(after.review.days.flatMap(\.items).isEmpty); XCTAssertNil(after.review.medianLifetime)
        XCTAssertEqual(after.review.importance.flatMap(\.items),[value.id])
    }
    func testImportanceKnownStarsAndConflictsPartitionActiveExactly() throws {
        var values = (1...6).map { TodoItem(title:"\($0)",stars:3,createdAt:now) }
        values[0].dueAt = now.addingTimeInterval(-1)
        values[1].dueAt = now
        values[2].dueAt = now.addingTimeInterval(-10)
        values[4].stars = 2; values[4].status = .completed; values[4].completedAt = now
        let issues: [UUID:Set<String>] = [values[2].id:["deadline"],values[3].id:["stars"]]
        let result = try calculate(AnalyticsInput(items:values,projects:[],issues:issues))
        XCTAssertEqual(result.review.importance.first { $0.stars == 3 }?.items.count,4)
        XCTAssertEqual(result.ids(for:.importance(3,.overdue)),[values[0].id])
        XCTAssertEqual(result.ids(for:.importance(3,.pending)),[values[2].id])
        XCTAssertEqual(Set(result.ids(for:.importance(3,.remaining))),Set([values[1].id,values[5].id]))
        XCTAssertEqual(result.ids(for:.importance(nil,.all)),[values[3].id])
        for group in result.review.importance {
            XCTAssertEqual(Set(group.overdue+group.pending+group.remaining),Set(group.items))
            XCTAssertEqual(group.overdue.count+group.pending.count+group.remaining.count,group.items.count)
        }
        XCTAssertEqual(Set(result.review.importance.flatMap(\.items)),Set(result.active))
    }
    func testImportanceLongWaitingUsesCalendarDaysAndExcludesUnknownCreation() throws {
        let values = [14,15,30,31,-1].map { TodoItem(title:"\($0)",stars:3,createdAt:calendar.date(byAdding:.day,value:-$0,to:now)!) }
        let result = try calculate(AnalyticsInput(items:values,projects:[]))
        XCTAssertEqual(Set(result.ids(for:.importance(3,.longWaiting))),Set(values[1...3].map(\.id)))
    }
    func testImportanceIgnoresHistoricalDateFilterButHonorsProjectAndMembershipConflict() throws {
        var input = sample(); input.issues[input.items[1].id] = ["stars"]
        let first = try calculate(input), second = try calculate(input,range:.custom(date("2026-10-01T00:00:00+08:00"),date("2026-10-05T00:00:00+08:00")))
        XCTAssertEqual(first.review.importance.map(\.items),second.review.importance.map(\.items))
        let unassigned = try calculate(input,scope:.unassigned)
        XCTAssertEqual(unassigned.review.importance.flatMap(\.items),unassigned.active)
        XCTAssertFalse(unassigned.review.importance.flatMap(\.items).contains(input.items[7].id))
    }
    func testAllReviewDetailsUseExactlyChartSampleIDs() throws {
        let result = try calculate(sample())
        let details: [AnalyticsDetail] = result.review.days.map { .completionDay($0.date) }
            + result.review.lifetimes.map { .lifetime($0.band) }
            + [.lifetimeIssues]
            + result.review.importance.flatMap { group in AnalyticsImportanceSlice.allCases.map { .importance(group.stars,$0) } }
        for detail in details { XCTAssertEqual(Set(result.records(for:detail).map(\.id)),Set(result.ids(for:detail))) }
    }
    func testHeatmapThresholdsCoverCountsWithoutDuplicateOrZeroRanges() throws {
        for count in [1,2,3,4,5,17] {
            let result = try calculate(AnalyticsInput(items:(0..<count).map { _ in completion(seconds:1) },projects:[]))
            let levels = result.review.heatmapThresholds
            XCTAssertEqual(levels,levels.sorted()); XCTAssertEqual(Set(levels).count,levels.count)
            XCTAssertEqual(levels,[1,3,6,Int.max]); XCTAssertGreaterThan(levels.first ?? 0,0)
        }
    }
    @MainActor
    func testReviewPageSwitchPreservesFiltersAndReusesSnapshot() async throws {
        let model = AnalyticsModel(); var reads = 0
        model.configure { reads += 1; return self.sample() }; model.activate(scope:.unassigned)
        defer { model.deactivate() }
        try await eventually { model.result != nil && !model.loading }
        let interval = model.result?.interval
        model.page = .review
        try await eventually { model.result != nil && !model.loading }
        XCTAssertEqual(model.scope,.unassigned); XCTAssertEqual(model.preset,.month)
        XCTAssertNotEqual(model.result?.interval,interval); XCTAssertEqual(reads,1)
        model.page = .summary; XCTAssertEqual(reads,1)
    }

    func testUpcomingUsesHalfOpenRealTwentyFourHoursAndExcludesUnknownDeadlines() throws {
        let offsets: [Double?] = [-1,0,1,86399,86400,nil,100]
        let items = offsets.enumerated().map { index, offset in TodoItem(title:"item \(index)",dueAt:offset.map { now.addingTimeInterval($0) },createdAt:now.addingTimeInterval(-10)) }
        let result = try calculate(AnalyticsInput(items:items,projects:[],issues:[items[6].id:["deadline"]]))
        XCTAssertEqual(Set(result.current.upcoming),Set([items[1].id,items[2].id,items[3].id]))
        XCTAssertEqual(result.overdue,[items[0].id]); XCTAssertTrue(Set(result.current.upcoming).isDisjoint(with:result.overdue))
        XCTAssertEqual(result.records(for:.upcoming).map(\.id),[items[1].id,items[2].id,items[3].id])
    }
    func testNowCountsAndTodayCompletionsIgnoreHistoricalRange() throws {
        let input = sample(), a = try calculate(input)
        let b = try calculate(input,range:.custom(date("2026-10-01T00:00:00+08:00"),date("2026-10-05T00:00:00+08:00")))
        XCTAssertEqual(a.current.upcoming,b.current.upcoming); XCTAssertEqual(a.current.todayCompleted,b.current.todayCompleted)
        XCTAssertEqual(a.current.attention,b.current.attention)
        XCTAssertEqual(b.completed.count,0); XCTAssertEqual(b.current.todayCompleted.count,1)
    }
    func testTodayCompletedUsesLocalCalendarDayAcrossDST() throws {
        var cal = calendar; cal.timeZone = TimeZone(identifier:"America/Los_Angeles")!
        let end = date("2026-11-01T23:30:00-08:00")
        let included = completion(seconds:0,end:date("2026-11-01T00:00:00-07:00"))
        let excluded = completion(seconds:0,end:date("2026-10-31T23:59:00-07:00"))
        let future = completion(seconds:0,end:end.addingTimeInterval(1))
        let result = try AnalyticsEngine.calculate(AnalyticsInput(items:[included,excluded,future],projects:[]),scope:.all,range:.recent(90),now:end,calendar:cal)
        XCTAssertEqual(result.current.todayCompleted,[included.id])
        XCTAssertGreaterThan(end.timeIntervalSince(included.completedAt!),86400)
    }
    func testUpcomingEntryAndExpiryAreScheduledWithoutDataEdits() throws {
        let due = now.addingTimeInterval(86400+3600)
        let item = TodoItem(title:"tomorrow",dueAt:due,createdAt:now.addingTimeInterval(-10))
        let input = AnalyticsInput(items:[item],projects:[])
        let initial = try calculate(input)
        XCTAssertTrue(initial.current.upcoming.isEmpty); XCTAssertEqual(initial.nextRefresh,now.addingTimeInterval(3600.1))
        let entered = try AnalyticsEngine.calculate(input,scope:.all,range:.recent(1),now:now.addingTimeInterval(3600.1),calendar:calendar)
        XCTAssertEqual(entered.current.upcoming,[item.id])
        let expired = try AnalyticsEngine.calculate(input,scope:.all,range:.recent(1),now:due.addingTimeInterval(0.1),calendar:calendar)
        XCTAssertTrue(expired.current.upcoming.isEmpty); XCTAssertEqual(expired.overdue,[item.id])
    }
    func testAttentionPriorityIsStableAndNeverDuplicatesItems() throws {
        let old = calendar.date(byAdding:.day,value:-20,to:now)!
        let late = TodoItem(title:"late",dueAt:now.addingTimeInterval(-100),stars:3,createdAt:old)
        let earlier = TodoItem(title:"earlier",dueAt:now.addingTimeInterval(-200),stars:1,createdAt:old)
        let soon = TodoItem(title:"soon",dueAt:now.addingTimeInterval(100),stars:3,createdAt:old)
        let waiting = TodoItem(title:"waiting",stars:3,createdAt:old)
        let pending = TodoItem(title:"unknown stars",stars:3,createdAt:old)
        let recent = TodoItem(title:"recent",stars:3,createdAt:now)
        let result = try calculate(AnalyticsInput(items:[waiting,soon,late,earlier,pending,recent],projects:[],issues:[pending.id:["stars"]]))
        XCTAssertEqual(result.current.attention,[earlier.id,late.id,soon.id,waiting.id])
        XCTAssertEqual(result.records(for:.attention).map(\.id),result.current.attention)
        XCTAssertEqual(Set(result.current.attention).count,result.current.attention.count)
    }
    func testAttentionPreviewCanTakeFiveWithoutTruncatingTheDetailCollection() throws {
        let items = (0..<12).map { TodoItem(title:"\($0)",dueAt:now.addingTimeInterval(-Double($0+1)),createdAt:now.addingTimeInterval(-60)) }
        let result = try calculate(AnalyticsInput(items:items,projects:[]))
        XCTAssertEqual(result.current.attention.count,12); XCTAssertEqual(result.records(for:.attention).count,12)
        XCTAssertEqual(result.current.attention.prefix(5),items.reversed().prefix(5).map(\.id)[...])
    }
    func testCurrentAggregatesRespectProjectScopeAndMembershipConflicts() throws {
        let input = sample(), result = try calculate(input,scope:.unassigned)
        XCTAssertEqual(result.current.upcoming.count,1); XCTAssertTrue(result.current.todayCompleted.isEmpty)
        XCTAssertFalse(result.current.attention.contains(input.items[7].id))
        XCTAssertEqual(result.current.attention,result.current.upcoming)
    }
    func testCompactProjectsKeepAllItemsAndSpecialGroupsAndExactOtherDetails() throws {
        let projects = (0..<9).map { Project(name:"p\($0)") }
        var items = projects.enumerated().flatMap { index, p in (0..<(index+1)).map { TodoItem(title:"\($0)",projectID:p.id,createdAt:now) } }
        items.append(TodoItem(title:"unassigned",createdAt:now))
        let pending = TodoItem(title:"pending",createdAt:now);items.append(pending)
        let result = try calculate(AnalyticsInput(items:items,projects:projects,issues:[pending.id:["membership"]]))
        let compact = result.compactGroups(.active)
        XCTAssertEqual(compact.count,8); XCTAssertEqual(compact.first { $0.key == .other }?.projectCount,4)
        XCTAssertEqual(Set(compact.flatMap(\.items)),Set(result.active))
        XCTAssertEqual(compact.flatMap(\.items).count,result.active.count)
        XCTAssertNotNil(compact.first { $0.key == .unassigned });XCTAssertNotNil(compact.first { $0.key == .pending })
        XCTAssertEqual(Set(result.ids(for:.project(.other,.active))),Set(result.activeProjects.filter { !compact.prefix(5).map(\.key).contains($0.key) && $0.key != .unassigned && $0.key != .pending }.flatMap(\.items)))
    }
    func testSingleRecordDetailDoesNotLeakAnItemAfterProjectTransfer() throws {
        let p = Project(name:"source"), q = Project(name:"target")
        let item = TodoItem(title:"moved",projectID:q.id,createdAt:now)
        let input = AnalyticsInput(items:[item],projects:[p,q])
        XCTAssertTrue(try calculate(input,scope:.project(p.id)).ids(for:.record(item.id)).isEmpty)
        XCTAssertEqual(try calculate(input,scope:.project(q.id)).ids(for:.record(item.id)),[item.id])
    }
    func testIssueBadgeUsesDeduplicatedScopedUnionAndKeepsGlobalMembershipSeparate() throws {
        let p = Project(name:"p")
        let a = TodoItem(title:"multiple issues",projectID:p.id,createdAt:now.addingTimeInterval(60))
        let b = TodoItem(title:"unknown project",createdAt:now)
        let input = AnalyticsInput(items:[a,b],projects:[p],issues:[a.id:["deadline","stars"],b.id:["membership"]])
        let all = try calculate(input), scoped = try calculate(input,scope:.project(p.id))
        XCTAssertEqual(Set(all.scopedIssues),Set([a.id,b.id]))
        XCTAssertEqual(scoped.scopedIssues,[a.id]);XCTAssertEqual(scoped.membershipIssues,[b.id])
        XCTAssertEqual(scoped.records(for:.issues).map(\.id),[a.id])
    }
    func testAdditionalDetailCollectionsReconcileWithSameResultIDs() throws {
        let result = try calculate(sample())
        let details: [AnalyticsDetail] = [.upcoming,.todayCompleted,.attention,.created,.lifetimeAll,.issues,.starIssues] + result.active.map { .record($0) }
        for detail in details { XCTAssertEqual(Set(result.records(for:detail).map(\.id)),Set(result.ids(for:detail))) }
        XCTAssertEqual(result.created.count,result.trend.flatMap(\.created).count)
    }
    @MainActor
    func testInvalidHiddenHistoryRangeCannotBreakNowPage() async throws {
        let model = AnalyticsModel(); var reads = 0
        model.configure { reads += 1; return self.sample() };model.activate(scope:.all)
        defer { model.deactivate() }
        try await eventually { model.result != nil && !model.loading }
        model.preset = .custom;model.customStart = Date.now;model.customEnd = Date.now.addingTimeInterval(-86400)
        XCTAssertNotNil(model.result);XCTAssertNil(model.error);XCTAssertEqual(reads,1)
        model.page = .review
        try await eventually { model.error != nil && !model.loading }
        XCTAssertNil(model.result)
        model.page = .summary
        try await eventually { model.result != nil && !model.loading }
        XCTAssertNil(model.error);XCTAssertEqual(reads,1)
    }
    @MainActor
    func testInspectorSelectionSurvivesWorkspaceLeaveAndClosesOnFilterChange() async throws {
        let model = AnalyticsModel()
        model.configure { self.sample() };model.activate(scope:.all)
        defer { model.deactivate() }
        try await eventually { model.result != nil && !model.loading }
        model.select(.attention);XCTAssertTrue(model.inspectorOpen)
        model.deactivate();model.activate(scope:.all)
        try await eventually { !model.loading }
        XCTAssertTrue(model.inspectorOpen);XCTAssertEqual(model.detail,.attention)
        model.scope = .unassigned
        XCTAssertFalse(model.inspectorOpen);XCTAssertEqual(model.composition,.importance)
        model.select(.active);model.closeDetails();XCTAssertFalse(model.inspectorOpen)
    }
    @MainActor
    func testDisplayChoicesDoNotRefetchOrResetHistoricalFilters() async throws {
        let model = AnalyticsModel();var reads = 0
        model.configure { reads += 1;return self.sample() };model.activate(scope:.all)
        defer { model.deactivate() }
        try await eventually { model.result != nil && !model.loading }
        model.preset = .quarter;model.composition = .waiting;model.timeline = .calendar
        model.page = .review
        try await eventually { model.result != nil && !model.loading }
        XCTAssertEqual(reads,1);XCTAssertEqual(model.preset,.quarter);XCTAssertEqual(model.result?.review.days.count,90)
        model.page = .summary
        try await eventually { model.result != nil && !model.loading }
        XCTAssertEqual(model.composition,.waiting);XCTAssertEqual(model.timeline,.calendar);XCTAssertEqual(model.preset,.quarter)
        XCTAssertEqual(model.result?.review.days.count,1);XCTAssertEqual(reads,1)
    }
}
