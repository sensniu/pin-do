import Foundation

struct AppPaths: Sendable {
    let root: URL
    var store: URL { root.appendingPathComponent("PinDo.store") }
    var manifest: URL { root.appendingPathComponent("StoreInfo.json") }
    var backups: URL { root.appendingPathComponent("Backups", isDirectory: true) }

    static func application(isDevelopment: Bool) throws -> AppPaths {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return AppPaths(root: support.appendingPathComponent(isDevelopment ? "PinDo-Development" : "PinDo", isDirectory: true))
    }
}

struct StoreManifest: Codable, Sendable {
    var formatVersion: Int = 2
    let storeID: UUID
    let createdAt: Date
    var lastAppVersion: String
    var migrationPending: Bool?
    var upgradeSnapshot: String?
}

enum StoreFailure: LocalizedError {
    case unsupportedVersion
    case inconsistentStore
    case alreadyOpen
    case invalidBackup
    case staleItem
    case invalidItem
    case invalidProject

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "数据由较新版本创建，请使用对应的新版本打开。原数据未被清空。"
        case .inconsistentStore: "数据文件不完整或存在重复记录。已停止写入，请使用备份恢复。"
        case .alreadyOpen: "另一个 PinDo 正在使用这份数据，请先关闭它。"
        case .invalidBackup: "备份格式、校验或内容不正确，当前数据未被替换。"
        case .staleItem: "此事项状态已变化，请重新打开后再操作。"
        case .invalidProject: "项目名称或状态不正确，未保存本次操作。"
        case .invalidItem: "事项内容或时间状态不正确，未保存本次修改。"
        }
    }
}

