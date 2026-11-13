import SwiftUI

struct HelpView: View {
    @ObservedObject var navigation: AppNavigation
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(navigation.showShortcuts ? "快捷键说明" : "使用说明").font(.title2.weight(.semibold)); Spacer(); Button("完成") { navigation.present(nil) }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if navigation.showShortcuts {
                        shortcut("⌘N", "新建待办；已有编辑时返回当前编辑器")
                        shortcut("⌘↩", "保存编辑器中的待办")
                        shortcut("⌘,", "打开统一设置")
                        shortcut("⌘0", "适应当前白板")
                        shortcut("⌘W", "关闭窗口，保留后台运行")
                        shortcut("⌘Q", "两秒内按两次，或长按约一秒，退出 PinDo")
                        shortcut("Esc", "关闭当前面板或取消编辑；有未保存输入时会询问")
                    } else {
                        section("记录与完成", "点击 + 或按 ⌘N，只填标题即可保存。具体项目白板中新建时自动归属该项目。点击便利贴展开编辑；勾选表示完成，三秒内可以撤回最近一次完成。放弃待办会保留独立的放弃记录。")
                        section("摆放与浏览", "拖动便利贴自由摆放和堆叠，拖动空白处平移。新增不推动已有便利贴；重新排列会覆盖当前白板的手动位置。适应白板只调整视野。重启时重新自动排版。")
                        section("概览", "当前待办和逾期反映现在；本期完成与新增/完成趋势按所选日期计算。点击图表或数量查看对应事项。完成、放弃记录可以展开只读查看；活动事项可进入编辑。")
                        section("设置与项目", "⌘, 打开通用、外观、同步和数据设置。项目名称和颜色在“项目 → 管理项目…”修改。归档会把未完成事项转入未分配；恢复项目不自动移回事项。")
                        section("同步与数据", "在同步设置手动填写专用 WebDAV 目录。更改先保存在本机，再自动同步。暂停同步会同时暂停手动与自动同步。本地维护一份最新恢复备份，导出文件由你自行保存。")
                        section("关闭与退出", "关闭窗口只关闭界面。状态栏和 Dock 可以重新打开。登录自启默认关闭，开启后后台运行。替换安装新版本前请真正退出旧进程，保留本机数据目录。")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 620, height: 490)
    }
    private func shortcut(_ keys: String, _ description: String) -> some View {
        HStack(alignment: .top) { Text(keys).font(.system(.body, design: .monospaced)).frame(width: 90, alignment: .leading); Text(description).font(.callout) }
    }
    private func section(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); Text(description).font(.callout).foregroundStyle(.secondary) }
    }
}
