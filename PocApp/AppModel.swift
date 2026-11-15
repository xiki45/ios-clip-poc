//
//  AppModel.swift
//  PocApp · 剪贴板库（v13 起是正经的管理界面，不再是 POC 诊断面板）
//
//  数据全部走 App Group 里的 clip-items.json，和键盘共用同一份文件，
//  所以这里改完，键盘下次打开就是新数据。
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class LibraryModel: ObservableObject {

    // MARK: - 数据

    @Published var items: [ClipItem] = []
    @Published var query: String = ""
    @Published var filter: Filter = .all
    @Published var toast: String = ""
    @Published var editing: ClipItem?

    // 调试信息（原 POC 面板的内容，收进设置页）
    @Published var storagePath: String = ""
    @Published var isShared: Bool = false
    @Published var extensionList: String = ""
    @Published var lastWrite: String = "—"

    enum Filter: String, CaseIterable, Identifiable {
        case all, pinned, url, json, code, today, long
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .pinned: return "置顶"
            case .url: return "链接"
            case .json: return "JSON"
            case .code: return "代码"
            case .today: return "今天"
            case .long: return "长文"
            }
        }
    }

    private var store: ClipStore?
    private var timer: Timer?

    init() {
        load()
        // 键盘在别的进程写文件，这里没有文件监听可用，只能轮询
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.load(announce: false) }
        }
    }

    // MARK: - 加载

    func load(announce: Bool = true) {
        guard let dir = GroupStore.effectiveDirectory else {
            toast = "没有可写目录"
            return
        }
        if store == nil {
            store = ClipStore(directory: dir.url)
        }
        store?.load()
        isShared = dir.isShared
        storagePath = dir.url.path
        extensionList = embeddedExtension
        applyFilter()
        if announce { /* 首帧静默 */ }
    }

    private func applyFilter() {
        var list = store?.visibleItems(limit: 1000) ?? []

        switch filter {
        case .all: break
        case .pinned: list = list.filter { $0.pinned }
        case .url: list = list.filter { $0.kind == "url" }
        case .json: list = list.filter { $0.kind == "json" }
        case .code: list = list.filter { $0.kind == "code" }
        case .today: list = list.filter { Calendar.current.isDateInToday($0.updatedAt) }
        case .long: list = list.filter { $0.text.count > 200 }
        }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter { TextMatch.matches($0.text, query: q) }
        }
        items = list
    }

    func onQueryChanged() { applyFilter() }

    // MARK: - 条目操作

    func togglePin(_ item: ClipItem) {
        store?.togglePin(id: item.id)
        load()
        toast = item.pinned ? "已取消置顶" : "已置顶"
    }

    func delete(_ item: ClipItem) {
        store?.remove(id: item.id)
        load()
        toast = "已删除"
    }

    func copy(_ item: ClipItem) {
        UIPasteboard.general.string = item.text
        lastWrite = Self.fmt.string(from: Date())
        toast = "已复制到剪贴板"
    }

    func save(id: String, text: String) {
        let ok = store?.update(id: id, text: text) ?? false
        load()
        toast = ok ? "已保存" : "保存失败（内容为空？）"
    }

    func clearAll() {
        store?.clearAll()
        load()
        toast = "已清空（键盘里的历史也会一起没了）"
    }

    // MARK: - 导入导出

    func exportFile() -> URL? {
        guard let data = store?.exportData() else { return nil }
        let name = "clip-items-\(Self.stamp.string(from: Date())).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url)
            return url
        } catch {
            toast = "导出失败：\(error.localizedDescription)"
            return nil
        }
    }

    func importFile(_ url: URL) {
        let got = url.startAccessingSecurityScopedResource()
        defer { if got { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            toast = "读不了这个文件"
            return
        }
        let r = store?.importMerge(data) ?? (0, 0)
        load()
        toast = "导入完成：新增 \(r.0) 条，更新 \(r.1) 条"
    }

    // MARK: - 统计

    var totalCount: Int { store?.items.filter { !$0.deleted }.count ?? 0 }
    var pinnedCount: Int { store?.items.filter { !$0.deleted && $0.pinned }.count ?? 0 }
    var byteSize: Int {
        guard let url = GroupStore.effectiveDirectory?.url.appendingPathComponent(ClipStore.fileName),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else { return 0 }
        return n.intValue
    }

    var embeddedExtension: String {
        guard let url = Bundle.main.builtInPlugInsURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path),
              !names.isEmpty else { return "未找到 PlugIns（扩展没嵌进来）" }
        return names.joined(separator: ", ")
    }

    // MARK: - 辅助

    static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f
    }()
    static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f
    }()
}
