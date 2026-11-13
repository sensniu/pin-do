import Charts
import SwiftUI

struct AnalyticsDistributionView: View {
    enum Kind { case trend, projects(AnalyticsProjectMode), waiting }
    let result: AnalyticsResult
    @ObservedObject var model: AnalyticsModel
    let kind: Kind
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch kind {
        case .trend: trend(result)
        case .projects(let mode): projects(result, mode: mode)
        case .waiting: waiting(result)
        }
    }
    private func trend(_ result: AnalyticsResult) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("新增与完成").font(.headline); Spacer(); Text(result.weekly ? "按周 · 首尾按所选日期计算" : "按日").font(.caption).foregroundStyle(.secondary) }
                Text(period(result) + (result.interval.end > result.now ? " · 截至现在" : "") + " · 点击选择日期").font(.caption).foregroundStyle(.secondary)
                let maximum = max(1, result.trend.flatMap { [$0.created.count, $0.completed.count] }.max() ?? 0)
                Chart {
                    ForEach(result.trend) { bucket in
                        BarMark(x: .value("日期", bucket.id), y: .value("事项数", bucket.created.count))
                            .foregroundStyle(by: .value("系列", "新增")).position(by: .value("系列", "新增"))
                            .accessibilityLabel(result.bucketLabel(bucket) + "新增").accessibilityValue("\(bucket.created.count)项")
                        BarMark(x: .value("日期", bucket.id), y: .value("事项数", bucket.completed.count))
                            .foregroundStyle(by: .value("系列", "完成")).position(by: .value("系列", "完成"))
                            .accessibilityLabel(result.bucketLabel(bucket) + "完成").accessibilityValue("\(bucket.completed.count)项")
                    }
                    if let selected = model.selectedTrend, result.trend.contains(where: { $0.id == selected }) {
                        RuleMark(x: .value("选择日期", selected)).foregroundStyle(Color.secondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartForegroundStyleScale(domain: ["新增", "完成"], range: [Color.secondary.opacity(0.6), Color.green])
                .chartYScale(domain: 0...maximum)
                .chartYAxis { AxisMarks(values: ticks(maximum)) }
                .chartYAxisLabel("事项数")
                .chartLegend(position: .top, alignment: .leading)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { location in
                            guard let frame = proxy.plotFrame.map({ geometry[$0] }), frame.contains(location) else { return }
                            let x = location.x - frame.minX
                            let candidates = result.trend.compactMap { bucket -> (AnalyticsTrendBucket, CGFloat)? in
                                proxy.position(forX: bucket.id).map { (bucket, $0) }
                            }
                            if let closest = candidates.min(by: { abs($0.1 - x) < abs($1.1 - x) }) {
                                model.selectedTrend = closest.0.id
                            }
                        }
                    }
                }.frame(height: 235)
                if let selected = result.trend.first(where: { $0.id == model.selectedTrend }) {
                    HStack {
                        Text(result.bucketLabel(selected)).font(.caption)
                        Spacer()
                        Button("新增 \(selected.created.count)") { model.select(.createdBucket(selected.id)) }
                        Button("完成 \(selected.completed.count)") { model.select(.completedBucket(selected.id)) }
                    }.buttonStyle(.link).font(.callout)
                }
                if result.trend.allSatisfy({ $0.created.isEmpty && $0.completed.isEmpty }) { Text("这段时间还没有新增或完成记录。").font(.callout).foregroundStyle(.secondary) }
                DisclosureGroup("查看准确数量与事项") {
                    LazyVStack(spacing: 8) {
                        ForEach(result.trend) { bucket in
                            HStack {
                                Text(result.bucketLabel(bucket)).font(.caption)
                                Spacer()
                                Button("新增 \(bucket.created.count)") { model.select(.createdBucket(bucket.id)) }
                                Button("完成 \(bucket.completed.count)") { model.select(.completedBucket(bucket.id)) }
                            }.buttonStyle(.link).padding(.vertical, 2)
                        }
                    }.padding(.top, 8)
                }.font(.caption)
            }.padding(10)
        }
    }
    private func projects(_ result: AnalyticsResult, mode: AnalyticsProjectMode) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Text("项目分布").font(.headline)
                let groups = model.expandedProjects ? result.groups(mode) : result.compactGroups(mode)
                if result.groups(mode).count > result.compactGroups(mode).count {
                    Button(model.expandedProjects ? "收起完整分布" : "查看完整项目分布") { model.expandedProjects.toggle() }.font(.caption)
                }
                if groups.isEmpty { Text("当前范围暂无对应事项。").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 180) }
                else {
                    let maximum = max(1, groups.map { $0.items.count }.max() ?? 0)
                    ScrollView {
                        Chart(groups) { group in
                            BarMark(x: .value("事项数", group.items.count), y: .value("项目", group.id))
                                .foregroundStyle(mode == .completed ? Color.green.opacity(0.65) : Color.secondary.opacity(0.45))
                                .annotation(position: .trailing) { Text((model.inspectorOpen && model.detail == .project(group.key, mode) ? "✓ " : "") + "\(group.items.count)").font(.caption).monospacedDigit() }
                                .accessibilityLabel(groupLabel(group)).accessibilityValue("\(group.items.count)项")
                        }
                        .chartXScale(domain: 0...maximum)
                        .chartXAxis { AxisMarks(values: ticks(maximum)) }
                        .chartXAxisLabel("事项数")
                        .chartYAxis {
                            AxisMarks { value in
                                AxisValueLabel { if let id = value.as(String.self), let group = groups.first(where: { $0.id == id }) {
                                    Text(groupLabel(group)).lineLimit(1).help(result.projectName(group.key))
                                } }
                            }
                        }
                        .chartOverlay { proxy in
                            GeometryReader { geometry in
                                Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { location in
                                    guard let frame = proxy.plotFrame.map({ geometry[$0] }), frame.contains(location),
                                          let id: String = proxy.value(atY: location.y - frame.minY), let group = groups.first(where: { $0.id == id }) else { return }
                                    model.select(.project(group.key, mode))
                                }
                            }
                        }.frame(height: max(170, CGFloat(groups.count * 34 + 38))).padding(.trailing, 16)
                    }.frame(height: min(270, max(180, CGFloat(groups.count * 34 + 48))))
                    DisclosureGroup("查看项目数量") {
                        ForEach(groups) { group in
                            Button { model.select(.project(group.key, mode)) } label: {
                                HStack { Circle().fill(projectColor(group.key, result: result)).frame(width: 7, height: 7); Text(groupLabel(group)); Spacer(); Text("\(group.items.count)").monospacedDigit() }
                            }.buttonStyle(.link).font(.caption).padding(.vertical, 3)
                        }
                    }.font(.caption)
                }
                Text(mode == .active ? "当前数量，不随历史日期筛选变化。" : "按所选期间的完成结果统计，包含归档项目。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
    }
    private func waiting(_ result: AnalyticsResult) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Text("等待多久").font(.headline)
                Text("从创建日期起跨过的日历天数，反映当前待办。").font(.caption).foregroundStyle(.secondary)
                let maximum = max(1, result.ages.map { $0.items.count }.max() ?? 0)
                Chart(result.ages) { group in
                    BarMark(x: .value("事项数", group.items.count), y: .value("等待时间", group.age.label))
                        .foregroundStyle(group.age == .unknown ? Color.orange : Color.purple.opacity(group.age == .older ? 0.95 : 0.55))
                        .annotation(position: .trailing) { Text((model.inspectorOpen && model.detail == .age(group.age) ? "✓ " : "") + "\(group.items.count)").font(.caption).monospacedDigit() }
                        .accessibilityLabel(group.age.label).accessibilityValue("\(group.items.count)项")
                }
                .chartXScale(domain: 0...maximum)
                .chartXAxis { AxisMarks(values: ticks(maximum)) }
                .chartXAxisLabel("事项数")
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { location in
                            guard let frame = proxy.plotFrame.map({ geometry[$0] }), frame.contains(location),
                                  let label: String = proxy.value(atY: location.y - frame.minY), let age = result.ages.first(where: { $0.age.label == label })?.age else { return }
                            model.select(.age(age))
                        }
                    }
                }.frame(height: 220).padding(.trailing, 16)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], alignment: .leading, spacing: 8) {
                    ForEach(result.ages) { group in
                        Button("\(group.age.label)：\(group.items.count)") { model.select(.age(group.age)) }.buttonStyle(.link).font(.caption)
                    }
                }
            }.padding(10)
        }
    }
    private func projectColor(_ key: AnalyticsProjectKey, result: AnalyticsResult) -> Color {
        guard case .project(let id) = key, let project = result.input.projects.first(where: { $0.id == id }) else { return key == .pending ? .orange : .secondary }
        func component(_ value: Double) -> Double { scheme == .dark ? value * 0.7 + 0.3 : value }
        return Color(red: component(project.red), green: component(project.green), blue: component(project.blue))
    }
    private func groupLabel(_ group: AnalyticsProjectGroup) -> String {
        group.key == .other ? "其他\(group.projectCount)个项目" : result.projectName(group.key)
    }
    private func period(_ result: AnalyticsResult) -> String { result.periodLabel }
    private func ticks(_ maximum: Int) -> [Int] { Array(stride(from: 0, through: maximum, by: max(1, Int(ceil(Double(maximum) / 4))))) }
}
