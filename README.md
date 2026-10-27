# PinDo

Mac 原生便利贴白板待办软件。当前版本 **v0.2.0**：支持按项目切换白板、全部待办总览和独立的未分配白板，保留 v0.1 的紧凑便利贴、DDL 变色、星数、缩放和 3 秒完成撤回。

需求和后续规划维护在 [PROJECT_PLAN.md](PROJECT_PLAN.md)；安装、升级和数据说明见 [INSTALL.md](INSTALL.md)。

## 安装

安装包：`build/releases/PinDo-0.2.0-arm64.dmg`，适用于 Apple silicon、macOS 14 及以上。

1. 退出正在运行的旧版 PinDo。升级前可从“数据 → 导出备份…”另存一份备份。
2. 打开 DMG，选中 `PinDo.app`，按 `⌘C`。
3. 在访达按 `⇧⌘A` 打开“应用程序”，按 `⌘V`，升级时选择替换。
4. 推出镜像，从“应用程序”启动。软件先检查本地数据，按需要自动备份和升级，再显示白板。

新安装从空白白板开始；升级会保留旧事项、完成/放弃历史与草稿，将原类别转换为项目。内部 ID 和关联自动维护，不需要手动转换数据。替换程序不会删除 `~/Library/Application Support/PinDo/`。

## 日常操作

- 点击 `+` 或 `⌘N` 新增，只填标题即可保存。星数默认 1，DDL 和备注可选。
- 在具体项目白板新建时自动归属该项目；在全部或未分配白板中默认未分配。点击编辑器的项目标签可按需更改。
- 右上角项目栏图标打开右侧栏；侧栏内的图钉可固定显示，拖动左边缘可调整宽度。固定状态和宽度自动记住。
- 点击全部待办、未分配或具体项目切换白板，每次切换刷新并重新排版、适配。停留在同一白板编辑 DDL 不重排。
- “项目管理”支持新建、重命名、归档、恢复和删除。归档自动将未完成事项转入未分配；恢复不自动移回。同名项目通过独立 ID 区分。
- 删除项目时，选择将未完成事项转入未分配或放弃；已完成历史及原项目关联保留。
- 便利贴右上角归档图标代表完成；全窗口只保留最近一次完成的 3 秒撤回控件，切换白板不重置倒计时。
- 点击便利贴展开编辑；删除代表放弃并保留独立记录。双指缩放、滚动或拖动白板浏览，`⌘0` 适应白板。
- 外观随 macOS 切换；无 DDL 为中性灰，临近 DDL 渐变紫，逾期暂用珊瑚色并排在外围。边框区分项目。

项目和事项 ID 不需要用户配置。当前没有归档事项浏览、分析、云同步、自动下载更新或颜色设置界面。

## 开发与测试

技术栈为 Swift + SwiftUI + Combine + SwiftData，无第三方依赖，无 Python/Conda 运行环境要求。完整 Xcode 用于开发，独立应用日常运行不需要 Xcode。

```sh
zsh scripts/build-app.sh       # Debug
zsh scripts/build-app.sh Release
zsh scripts/test.sh
zsh scripts/package-dmg.sh
```

或用 Xcode 打开 `PinDo.xcodeproj`，选择 `PinDo` / `My Mac` 运行。所有构建产物集中在 `build/`，被 Git 忽略。

- Debug：`local.pindo.development`，数据位于 `~/Library/Application Support/PinDo-Development/`。
- Release：`local.pindo.app`，正式数据位于 `~/Library/Application Support/PinDo/`。
- XCTest：使用任务专属临时目录，结束后清理；不访问正式数据。
- `--demo`：显式内存预览模式，不保存数据。

当前 **33 项测试通过**。仓库测试使用真实临时数据库，覆盖项目生命周期、批量回滚、项目来源、同名项目、旧格式数据库和备份转换、迁移中断恢复、存储缺失保护及备份校验。白板测试覆盖自动归属、筛选、位置规则、跨白板撤回。原有时间、排序及 0/1/20/100/300 张布局测试保留；300 张仅验证布局计算，不代表已测量大量卡片渲染性能。

图标来自 `asset/pin-do.png`，`scripts/generate-icon.sh` 可生成多分辨率 ICNS。打包脚本先测试、构建 Release，再做本机临时签名和镜像校验；受限环境使用 UDF 镜像，内容为应用与安装说明，不包含用户数据库、日志或构建缓存。

SwiftData 物理模型继续使用显式 PersistentModel backing/observation，逻辑数据格式升级为 v2。以后修改存储必须验证旧数据迁移，不允许清空原数据库掩盖加载错误。
