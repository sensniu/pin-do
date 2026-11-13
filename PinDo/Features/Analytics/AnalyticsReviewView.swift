import Charts
import SwiftUI

struct AnalyticsReviewView: View {
    enum Content { case calendar, lifetime, importance }
    let result: AnalyticsResult
    let selected: AnalyticsDetail
    let select: (AnalyticsDetail) -> Void
    let content: Content
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        switch content {
        case .calendar: completionCalendar
        case .lifetime: lifetime
        case .importance: importance
        }
    }

    private var completionCalendar: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("完成日历").font(.headline)
                    Spacer()
                    Text("本期完成 \(result.completed.count) 项").font(.callout).monospacedDigit()
                }
                Text(result.periodLabel + " · 周一开始").font(.caption).foregroundStyle(.secondary)
                calendarGrid
                let thresholds = heatmapThresholds
                HStack(spacing: 10) {
                    Text("每日完成").font(.caption).foregroundStyle(.secondary)
                    legendSwatch(level: 0, label: "0")
                    ForEach(Array(thresholds.enumerated()), id: \.offset) { index, upper in
                        let lower = index == 0 ? 1 : thresholds[index - 1] + 1
                        legendSwatch(level: index + 1, label: upper == Int.max ? "7+" : lower == upper ? "\(upper)" : "\(lower)–\(upper)")
                    }
                    Spacer(minLength: 0)
                }
                if result.completed.isEmpty { Text("这段时间还没有完成记录。").font(.callout).foregroundStyle(.secondary) }
                Text("点击日期查看事项 · 空白格不在所选范围内")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
    }

    private var calendarGrid: some View {
        let leading = (result.calendar.component(.weekday, from: result.interval.start) + 5) % 7
        let weeks = (leading + result.review.days.count + 6) / 7
        return HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 4) {
                Color.clear.frame(width: 18, height: 16)
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { day in
                    Text(day).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 18, height: 22)
                }
            }.accessibilityHidden(true)
            ScrollViewReader { scroll in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 4) {
                        ForEach(0..<weeks, id: \.self) { week in
                            VStack(spacing: 4) {
                                Text(weekLabel(week, leading: leading)).font(.system(size: 9)).foregroundStyle(.secondary)
                                    .frame(width: 22, height: 16).accessibilityHidden(true)
                                ForEach(0..<7, id: \.self) { weekday in
                                    let index = week * 7 + weekday - leading
                                    if result.review.days.indices.contains(index) { calendarCell(result.review.days[index]) }
                                    else { Color.clear.frame(width: 22, height: 22).accessibilityHidden(true) }
                                }
                            }.id(week)
                        }
                    }.padding(2)
                }.scrollIndicators(.visible)
                    .onAppear { scroll.scrollTo(weeks - 1, anchor: .trailing) }
                    .onChange(of: result.interval) { _, _ in scroll.scrollTo(weeks - 1, anchor: .trailing) }
            }
        }.frame(height: 210).accessibilityElement(children: .contain).accessibilityLabel("完成日历，周一至周日")
    }

    private func weekLabel(_ week: Int, leading: Int) -> String {
        let index = max(0, week * 7 - leading)
        guard result.review.days.indices.contains(index) else { return "" }
        let date = result.review.days[index].date
        let day = result.calendar.component(.day, from: date)
        return week == 0 || day <= 7 ? "\(result.calendar.component(.month, from: date))月" : ""
    }

    private var heatmapThresholds: [Int] {
        result.review.heatmapThresholds
    }

    private func heatmapColor(_ level: Int) -> Color {
        if level == 0 { return .primary.opacity(scheme == .dark ? 0.10 : 0.055) }
        let fraction = Double(level) / Double(max(1, heatmapThresholds.count))
        return Color.green.opacity(0.25 + fraction * 0.65)
    }

    private func legendSwatch(level: Int, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(heatmapColor(level)).frame(width: 12, height: 12)
            Text(label).font(.caption).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }

    private func calendarCell(_ day: AnalyticsCompletionDay) -> some View {
        let level = day.items.isEmpty ? 0 : (heatmapThresholds.firstIndex { day.items.count <= $0 } ?? 0) + 1
        let chosen = selected == .completionDay(day.date)
        let today = result.calendar.isDate(day.date, inSameDayAs: result.now)
        let label = result.dayLabel(day.date) + "，完成\(day.items.count)项" + (today ? "，今天" : "")
        return Button { select(.completionDay(day.date)) } label: {
            RoundedRectangle(cornerRadius: 4).fill(heatmapColor(level))
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(chosen ? Color.accentColor : .primary.opacity(today ? 0.65 : 0.12), lineWidth: chosen ? 2 : 1) }
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
            .accessibilityValue(chosen ? "已选择" : "")
    }

    private var lifetime: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("创建到完成的分布").font(.headline)
                    AnalyticsInfoButton(message: "从创建到完成的实际跨度，包含等待，不是实际工时。一天按24小时计算，各组包含左端点、不含右端点；异常时间不计入计算，但事项仍保留。")
                }
                Text("\(result.review.durations.count)项可计算记录 · 含等待时间").font(.caption).foregroundStyle(.secondary)
                lifetimeChart
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading, spacing: 8) {
                    ForEach(result.review.lifetimes) { group in
                        Button("\(group.band.label)：\(group.items.count)") { select(.lifetime(group.band)) }.buttonStyle(.link).font(.caption)
                    }
                }
                if !result.review.lifetimeIssues.isEmpty {
                    Button("\(result.review.lifetimeIssues.count)项时间待核对，未计入以上样本") { select(.lifetimeIssues) }
                        .buttonStyle(.link).font(.caption)
                }
                if result.review.durations.isEmpty { Text("还没有可用于计算存续时间的完成事项。").font(.callout).foregroundStyle(.secondary) }
            }.padding(10)
        }
    }

    private var lifetimeChart: some View {
        let maximum = max(1, result.review.lifetimes.map { $0.items.count }.max() ?? 0)
        return Chart(result.review.lifetimes) { group in
            BarMark(x: .value("事项数", group.items.count), y: .value("创建至完成", group.band.label))
                .foregroundStyle(Color.purple.opacity(selected == .lifetime(group.band) ? 0.95 : 0.6))
                .annotation(position: .trailing) { Text((selected == .lifetime(group.band) ? "✓ " : "") + "\(group.items.count)").font(.caption).monospacedDigit() }
                .accessibilityLabel(group.band.label).accessibilityValue("\(group.items.count)项")
        }
        .chartXScale(domain: 0...maximum).chartXAxis { AxisMarks(values: ticks(maximum)) }.chartXAxisLabel("事项数")
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { location in
                    guard let frame = proxy.plotFrame.map({ geometry[$0] }), frame.contains(location),
                          let label: String = proxy.value(atY: location.y - frame.minY),
                          let group = result.review.lifetimes.first(where: { $0.band.label == label }) else { return }
                    select(.lifetime(group.band))
                }
            }
        }.frame(height: 220).padding(.trailing, 16)
    }

    private var importance: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Text("按星级").font(.headline)
                importanceChart
                ForEach(result.review.importance) { group in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text((selectedImportance(group) ? "✓ " : "") + group.label).font(.caption.weight(.medium))
                            Spacer()
                            Button("全部 \(group.items.count)") { select(.importance(group.stars, .all)) }
                            Button("逾期 \(group.overdue.count)") { select(.importance(group.stars, .overdue)) }
                        }
                        HStack {
                            if !group.pending.isEmpty { Button("截止待确认 \(group.pending.count)") { select(.importance(group.stars, .pending)) } }
                            Spacer(minLength: 0)
                            Button("等待15天及以上 \(group.longWaiting.count)") { select(.importance(group.stars, .longWaiting)) }
                        }
                    }.buttonStyle(.link).font(.caption).padding(6)
                        .background(.primary.opacity(selectedImportance(group) ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 6))
                }
                Text("其余待办包括尚未逾期和无截止时间的事项。星级有冲突时不会代为选择。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
    }

    private var importanceChart: some View {
        let maximum = max(1, result.review.importance.map { $0.items.count }.max() ?? 0)
        let slices: [AnalyticsImportanceSlice] = [.overdue, .pending, .remaining]
        return Chart {
            ForEach(result.review.importance) { group in
                ForEach(slices, id: \.self) { slice in
                    BarMark(x: .value("事项数", group.ids(slice).count), y: .value("重要程度", group.label))
                        .foregroundStyle(by: .value("状态", slice.rawValue))
                        .accessibilityLabel(group.label + slice.rawValue).accessibilityValue("\(group.ids(slice).count)项")
                }
            }
        }
        .chartForegroundStyleScale(domain: slices.map(\.rawValue), range: [overdueColor, Color.purple.opacity(0.65), Color.secondary.opacity(0.4)])
        .chartLegend(position: .bottom, alignment: .leading)
        .chartXScale(domain: 0...maximum).chartXAxis { AxisMarks(values: ticks(maximum)) }.chartXAxisLabel("事项数")
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { location in
                    guard let frame = proxy.plotFrame.map({ geometry[$0] }), frame.contains(location),
                          let label: String = proxy.value(atY: location.y - frame.minY),
                          let group = result.review.importance.first(where: { $0.label == label }),
                          let value: Double = proxy.value(atX: location.x - frame.minX) else { return }
                    let slice: AnalyticsImportanceSlice = value < Double(group.overdue.count) ? .overdue
                        : value < Double(group.overdue.count + group.pending.count) ? .pending : .remaining
                    select(.importance(group.stars, slice))
                }
            }
        }.frame(height: 220)
    }

    private func ticks(_ maximum: Int) -> [Int] {
        Array(stride(from: 0, through: maximum, by: max(1, Int(ceil(Double(maximum) / 4)))))
    }
    private var overdueColor: Color {
        let c = appearance.palette.overdue
        func component(_ x: Double) -> Double { scheme == .dark ? x * 0.45 + 0.55 : x * 0.55 }
        return Color(red: component(c.red), green: component(c.green), blue: component(c.blue))
    }
    private func selectedImportance(_ group: AnalyticsImportanceGroup) -> Bool {
        if case .importance(let stars, _) = selected { return stars == group.stars }
        return false
    }
}
