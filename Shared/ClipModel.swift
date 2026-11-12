//
//  ClipModel.swift
//  剪贴板数据模型 + 本地存储（JSON，App Group 内共享）
//
//  设计取舍：MVP 用单个 JSON 文件而不是 SQLite。
//  理由：条目量在几千级，JSON 全量读写的耗时是毫秒级；而且同步协议本身就是 JSON，
//  少一层映射，Android / PC 端可以直接读写同一份格式。
//

import Foundation
import CryptoKit

// MARK: - 模型

public struct ClipItem: Codable, Equatable {
    public var id: String
    public var text: String
    public var hash: String
    public var createdAt: Date
    public var updatedAt: Date
    public var pinned: Bool
    public var source: String      // "app" | "keyboard" | "pc"
    public var rev: Int
    public var deleted: Bool

    public init(text: String, source: String = "unknown") {
        self.id = UUID().uuidString
        self.text = text
        self.hash = ClipItem.sha256(text)
        self.createdAt = Date()
        self.updatedAt = Date()
        self.pinned = false
        self.source = source
        self.rev = 1
        self.deleted = false
    }

    public static func sha256(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    public var preview: String {
        let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        return flat.count <= 120 ? flat : String(flat.prefix(120)) + "…"
    }

    public var kind: String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return "url" }
        if (t.hasPrefix("{") && t.hasSuffix("}")) || (t.hasPrefix("[") && t.hasSuffix("]")) { return "json" }
        if Double(t) != nil { return "number" }
        if t.contains("\n") && t.count > 80 { return "code" }
        return "text"
    }
}

// MARK: - 存储

public final class ClipStore {

    public private(set) var items: [ClipItem] = []
    public static let fileName = "clip-items.json"
    public static let maxItems = 500

    private let fileURL: URL
    private let queue = DispatchQueue(label: "clip.store")

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent(ClipStore.fileName)
        load()
    }

    // MARK: 读写

    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else { items = []; return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        items = (try? dec.decode([ClipItem].self, from: data)) ?? []
    }

    @discardableResult
    public func save() -> Bool {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(items) else { return false }
        return (try? data.write(to: fileURL, options: .atomic)) != nil
    }

    // MARK: 变更

    /// 去重写入：同样的内容只更新时间戳并置顶，不产生新条目
    @discardableResult
    public func upsert(_ text: String, source: String) -> ClipItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200_000 else { return nil }
        let h = ClipItem.sha256(text)

        if let idx = items.firstIndex(where: { $0.hash == h && !$0.deleted }) {
            items[idx].updatedAt = Date()
            items[idx].rev += 1
            items[idx].source = source
            let moved = items.remove(at: idx)
            items.insert(moved, at: 0)
            trim()
            save()
            return moved
        }

        let item = ClipItem(text: text, source: source)
        items.insert(item, at: 0)
        trim()
        save()
        return item
    }

    public func remove(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].deleted = true
        items[idx].rev += 1
        items[idx].updatedAt = Date()
        save()
    }

    public func togglePin(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].pinned.toggle()
        items[idx].rev += 1
        items[idx].updatedAt = Date()
        reorder()
        save()
    }

    public func clearAll() {
        items = []
        save()
    }

    // MARK: 查询

    /// 展示顺序：置顶在前，其余按更新时间倒序
    public func visibleItems(limit: Int = 200) -> [ClipItem] {
        items.filter { !$0.deleted }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                return a.updatedAt > b.updatedAt
            }
            .prefix(limit)
            .map { $0 }
    }

    public func search(_ query: String, limit: Int = 200) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return visibleItems(limit: limit) }
        let tokens = Tokenizer.tokens(q)
        return visibleItems(limit: Int.max).filter { item in
            let lower = item.text.lowercased()
            return tokens.allSatisfy { lower.contains($0) }
        }.prefix(limit).map { $0 }
    }

    private func reorder() {
        items.sort { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updatedAt > b.updatedAt
        }
    }

    private func trim() {
        let live = items.filter { !$0.deleted }
        guard live.count > ClipStore.maxItems else {
            reorder()
            return
        }
        let keep = Set(live.sorted { $0.updatedAt > $1.updatedAt }
            .prefix(ClipStore.maxItems)
            .map { $0.id })
        items = items.filter { keep.contains($0.id) || $0.pinned }
        reorder()
    }
}
