//
//  GroupStore.swift
//  Shared between PocApp (host) and ClipKeyboard (keyboard extension)
//
//  POC 1 的核心：验证 App Group 容器是否真的可用。
//  关键点：扩展与主 App 是两个独立进程，唯一的共享通道是 App Group 容器。
//  如果 containerURL(forSecurityApplicationGroupIdentifier:) 返回 nil，
//  说明签名时的 entitlements 没生效（自签/TrollStore 场景下最常见的问题）。
//

import Foundation

public struct PocLogEntry: Codable {
    public var ts: Double          // Unix timestamp
    public var source: String      // "app" | "keyboard" | "dylib"
    public var event: String       // "group_write" | "group_read" | "pasteboard" | ...
    public var detail: String

    public init(source: String, event: String, detail: String) {
        self.ts = Date().timeIntervalSince1970
        self.source = source
        self.event = event
        self.detail = detail
    }

    public var isoTime: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}

public enum GroupStore {

    /// 必须与 PocApp.entitlements / ClipKeyboard.entitlements 中的
    /// com.apple.security.application-groups 完全一致。
    public static let groupID = "group.com.ouo.clipboardpoc"

    public static let logFileName = "poc-log.jsonl"
    public static let heartbeatFileName = "poc-heartbeat.json"

    // MARK: - 容器定位

    /// App Group 容器。nil = entitlement 未生效。
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    /// 主 App 与扩展各自的沙盒目录（仅用于判断“是否真的在共享”）
    public static var privateDocumentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// 实际写入目录：优先 App Group，失败则退化到自身沙盒（此时两端互不可见，正好用于对照）
    public static var effectiveDirectory: (url: URL, isShared: Bool)? {
        if let g = containerURL { return (g, true) }
        if let p = privateDocumentsURL { return (p, false) }
        return nil
    }

    // MARK: - 日志读写

    private static var logURL: URL? {
        effectiveDirectory?.url.appendingPathComponent(logFileName)
    }

    public static func append(_ entry: PocLogEntry) {
        guard let url = logURL else { return }
        appendRawLine(url: url, data: encodeLine(entry))
    }

    public static func appendBulk(_ entries: [PocLogEntry]) {
        guard let url = logURL, !entries.isEmpty else { return }
        let data = entries.reduce(into: Data()) { $0.append(encodeLine($1)) }
        appendRawLine(url: url, data: data)
    }

    private static func encodeLine(_ entry: PocLogEntry) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var d = (try? enc.encode(entry)) ?? Data()
        d.append(0x0A) // '\n'
        return d
    }

    private static func appendRawLine(url: URL, data: Data) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }

    public static func readAll(limit: Int = 500) -> [PocLogEntry] {
        guard let url = logURL, let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var out: [PocLogEntry] = []
        for line in lines.suffix(limit) {
            if let e = try? dec.decode(PocLogEntry.self, from: Data(line)) {
                out.append(e)
            }
        }
        return out
    }

    public static func clear() {
        guard let url = logURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 心跳（POC 3：后台存活）

    public static func writeHeartbeat(_ payload: [String: Any]) {
        guard let dir = effectiveDirectory?.url else { return }
        let url = dir.appendingPathComponent(heartbeatFileName)
        if let d = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]) {
            try? d.write(to: url)
        }
    }

    public static func readHeartbeat() -> [String: Any] {
        guard let dir = effectiveDirectory?.url else { return [:] }
        let url = dir.appendingPathComponent(heartbeatFileName)
        guard let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return obj
    }

    // MARK: - 诊断快照

    public static func snapshot(source: String) -> [String: String] {
        var s: [String: String] = [:]
        s["source"] = source
        s["bundle_id"] = Bundle.main.bundleIdentifier ?? "?"
        s["group_id"] = groupID
        s["group_container"] = containerURL?.path ?? "nil (entitlement 未生效)"
        s["private_documents"] = privateDocumentsURL?.path ?? "nil"
        s["effective_dir"] = effectiveDirectory?.url.path ?? "nil"
        s["is_shared"] = (effectiveDirectory?.isShared ?? false) ? "YES" : "NO"
        s["log_exists"] = (logURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false) ? "YES" : "NO"
        s["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        return s
    }
}
