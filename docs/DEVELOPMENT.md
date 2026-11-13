# 开发与测试

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

自动化检查使用真实临时数据库与模拟WebDAV，不访问正式库和真实账号。v1.0.0发布验证中 **222项非UI测试通过，0失败**，覆盖0.13.0到1.0.0升级时保留业务/草稿/待发同步。Release构建、本机临时签名严格检查、安装镜像CRC及SHA-256校验通过。图标实际2×渲染与确认稿逐像素一致。上述检查不包含真实WebDAV账号联调、开机登录及所有窗口尺寸的完整UI验收。

图标来自 `asset/pin-do.png`，`scripts/generate-icon.sh` 可生成多分辨率 ICNS。打包脚本先测试、构建 Release，再做本机临时签名和镜像校验；受限环境使用 UDF 镜像，内容为应用、可拖入安装的“应用程序”Finder 替身及安装说明，不包含用户数据库、日志或构建缓存。

SwiftData 物理模型继续使用显式 PersistentModel backing/observation。普通本地库保持逻辑格式 v2，首次启用同步或恢复 v3 备份后使用 v3，包含业务记录、当前字段候选、outbox/inbox 和有限的确认进度；不再永久保存全部编辑正文及传输包。以后修改存储必须验证旧数据迁移，不允许清空原数据库掩盖加载错误。Debug 与 Release 的本地目录和钥匙串服务分离，联调时还应手动指定不同的 WebDAV 测试目录。

相关文档：[使用指南](USAGE.md) · [同步说明](WEBDAV.md)。
