// 本机跑同步引擎的替身：SyncConfig 真实实现在 iOS 侧依赖 UIKit，这里给个同构版本
import Foundation

public struct SyncConfig: Codable, Equatable {
    public var server: String = ""
    public var username: String = ""
    public var password: String = ""
    public var deviceID: String = ""
    public var deviceName: String = ""
    public init() {}
    public var isValid: Bool { !server.trimmingCharacters(in: .whitespaces).isEmpty }
}
