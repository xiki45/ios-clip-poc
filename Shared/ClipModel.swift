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
    // v15：图片/附件支持。老数据没有这两个字段，Optional 让解码自动补 nil。
    public var type: String? = nil        // nil/"text" = 文本；"image" = 图片
    public var attachment: String? = nil  // attachments/ 下的文件名
    public var pixelSize: String? = nil   // "800×600"，仅展示用

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

    public static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    public static func sha256(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    public var preview: String {
        let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        return flat.count <= 120 ? flat : String(flat.prefix(120)) + "…"
    }

    public var isImage: Bool { type == "image" }

    public var kind: String {
        if isImage { return "image" }
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

    public static let attachmentsDirName = "attachments"

    private let fileURL: URL
    private let dirURL: URL
    private let queue = DispatchQueue(label: "clip.store")

    public init(directory: URL) {
        self.dirURL = directory
        self.fileURL = directory.appendingPathComponent(ClipStore.fileName)
        load()
    }

    public var attachmentsURL: URL {
        dirURL.appendingPathComponent(ClipStore.attachmentsDirName, isDirectory: true)
    }

    public func attachmentURL(for item: ClipItem) -> URL? {
        guard let name = item.attachment, !name.isEmpty else { return nil }
        return attachmentsURL.appendingPathComponent(name)
    }

    public func attachmentData(for item: ClipItem) -> Data? {
        guard let url = attachmentURL(for: item) else { return nil }
        return try? Data(contentsOf: url)
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

    /// 图片写入：按内容 hash 去重，正文落到 attachments/<hash>.png
    @discardableResult
    public func upsertImage(_ data: Data, source: String, pixel: String? = nil) -> ClipItem? {
        guard !data.isEmpty, data.count <= 20_000_000 else { return nil }
        let h = ClipItem.sha256(data)

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

        try? FileManager.default.createDirectory(at: attachmentsURL,
                                                 withIntermediateDirectories: true)
        let name = "\(h).png"
        guard (try? data.write(to: attachmentsURL.appendingPathComponent(name))) != nil else {
            return nil
        }

        var item = ClipItem(text: "［图片］" + (pixel ?? ""), source: source)
        item.type = "image"
        item.attachment = name
        item.pixelSize = pixel
        item.hash = h
        items.insert(item, at: 0)
        trim()
        save()
        return item
    }

    /// 撤销删除：把 tombstone 复活（rev+1 让其它设备也能看到）
    public func restore(_ item: ClipItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].deleted = false
            items[idx].rev += 1
            items[idx].updatedAt = Date()
        } else {
            var it = item
            it.deleted = false
            it.rev += 1
            items.insert(it, at: 0)
        }
        reorder()
        save()
    }

    /// 编辑正文：重算 hash、rev+1，并把条目挪到最前
    @discardableResult
    public func update(id: String, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200_000,
              let idx = items.firstIndex(where: { $0.id == id }) else { return false }
        items[idx].text = text
        items[idx].hash = ClipItem.sha256(text)
        items[idx].updatedAt = Date()
        items[idx].rev += 1
        let moved = items.remove(at: idx)
        items.insert(moved, at: 0)
        save()
        return true
    }

    /// 同步用：把远端附件落到本地 attachments/
    @discardableResult
    public func writeAttachment(named name: String, data: Data) -> Bool {
        guard !name.isEmpty else { return false }
        try? FileManager.default.createDirectory(at: attachmentsURL,
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: attachmentsURL.appendingPathComponent(name))) != nil
    }

    /// 同步用：整表替换（合并结果写回）
    public func replaceAll(_ newItems: [ClipItem]) {
        items = newItems
        reorder()
        save()
    }

    // MARK: 导入导出

    public func exportData() -> Data? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(items)
    }

    /// 按 id/rev 归并导入。返回 (新增, 更新)
    @discardableResult
    public func importMerge(_ data: Data) -> (Int, Int) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let incoming = try? dec.decode([ClipItem].self, from: data) else { return (0, 0) }

        var added = 0, updated = 0
        for inc in incoming {
            if let idx = items.firstIndex(where: { $0.id == inc.id }) {
                if inc.rev > items[idx].rev {
                    items[idx] = inc
                    updated += 1
                }
            } else if let idx = items.firstIndex(where: { $0.hash == inc.hash && $0.id != inc.id }) {
                if inc.updatedAt > items[idx].updatedAt {
                    items[idx].updatedAt = inc.updatedAt
                    items[idx].rev += 1
                    updated += 1
                }
            } else {
                items.append(inc)
                added += 1
            }
        }
        if added + updated > 0 {
            reorder()
            trim()
            save()
        }
        return (added, updated)
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
        return visibleItems(limit: Int.max).filter { item in
            TextMatch.matches(item.text, query: q)
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
