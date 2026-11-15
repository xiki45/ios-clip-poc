//
//  SyncConfig.swift
//  同步配置（服务器地址 / 账号 / 设备标识）
//
//  存在 App Group 的 UserDefaults 里：以后键盘要自己触发同步也能直接读到。
//  密码存 UserDefaults —— 这是个自用侧载 App，没有 Keychain 共享的收益，
//  但别把这份配置导出给别人。
//

import Foundation
import UIKit

public struct SyncConfig: Codable, Equatable {
    public var server: String = ""
    public var username: String = ""
    public var password: String = ""
    public var deviceID: String = ""
    public var deviceName: String = ""

    public init() {}

    public var isValid: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

public enum SyncConfigStore {

    private static let key = "wt_sync_config"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: GroupStore.groupID)
    }

    public static func load() -> SyncConfig {
        var c = SyncConfig()
        if let d = defaults?.data(forKey: key),
           let decoded = try? JSONDecoder().decode(SyncConfig.self, from: d) {
            c = decoded
        }
        if c.deviceID.isEmpty {
            c.deviceID = UUID().uuidString
        }
        if c.deviceName.isEmpty {
            c.deviceName = UIDevice.current.name
        }
        return c
    }

    public static func save(_ config: SyncConfig) {
        guard let d = try? JSONEncoder().encode(config) else { return }
        defaults?.set(d, forKey: key)
    }

    public static func reset() {
        defaults?.removeObject(forKey: key)
    }
}
