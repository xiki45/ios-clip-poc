//
//  ContentView.swift
//  PocApp · v13 剪贴板库
//
//  历史条目管理：搜索、分类、置顶、编辑、删除、导入导出。
//  数据来自 App Group 共享容器，键盘会立刻看到改动。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension ClipItem: Identifiable {}

// MARK: - 主界面

struct ContentView: View {
    @StateObject private var model = LibraryModel()
    @State private var showSettings = false
    @State private var showClearConfirm = false
    @State private var showImporter = false
    @State private var shareURL: URL?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                filterBar
                listOrEmpty
            }
            .navigationTitle("剪贴板 \(model.totalCount)")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索历史")
            .onChange(of: model.query) { _ in model.onQueryChanged() }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { shareURL = model.exportFile() } label: {
                            Label("导出 JSON", systemImage: "square.and.arrow.up")
                        }
                        Button { showImporter = true } label: {
                            Label("导入 JSON", systemImage: "square.and.arrow.down")
                        }
                        Divider()
                        Button(role: .destructive) { showClearConfirm = true } label: {
                            Label("清空全部", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView(model: model) }
            .sheet(item: $model.editing) { item in
                EditItemView(item: item) { text in
                    model.save(id: item.id, text: text)
                    model.editing = nil
                } onCancel: {
                    model.editing = nil
                }
            }
            .sheet(item: Binding(
                get: { shareURL.map(ShareBox.init) },
                set: { if $0 == nil { shareURL = nil } }
            )) { box in
                ShareSheet(url: box.url)
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.json, .text],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let u = urls.first {
                    model.importFile(u)
                }
            }
            .alert(isPresented: $showClearConfirm) {
                Alert(title: Text("清空全部历史？"),
                      message: Text("键盘里看到的历史也会一起消失，不可撤销。"),
                      primaryButton: .destructive(Text("清空")) { model.clearAll() },
                      secondaryButton: .cancel(Text("取消")))
            }
            .overlay(alignment: .bottom) {
                if !model.toast.isEmpty {
                    Text(model.toast)
                        .font(.footnote)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            }
            .onChange(of: model.toast) { t in
                guard !t.isEmpty else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    if model.toast == t { model.toast = "" }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: 分类 chip

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(LibraryModel.Filter.allCases) { f in
                    Button {
                        model.filter = f
                        model.onQueryChanged()
                    } label: {
                        Text(f.title)
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(model.filter == f ? Color.accentColor : Color(.secondarySystemBackground))
                            .foregroundColor(model.filter == f ? .white : .primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    // MARK: 列表

    @ViewBuilder
    private var listOrEmpty: some View {
        if model.items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard").font(.largeTitle).foregroundColor(.secondary)
                Text(model.query.isEmpty ? "还没有记录" : "没有匹配「\(model.query)」的条目")
                    .font(.subheadline).foregroundColor(.secondary)
                if model.query.isEmpty {
                    Text("切到 ClipKeyboard 复制一次内容就会出现在这里")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.items, id: \.id) { item in
                    ItemRow(item: item, onCopy: { model.copy(item) })
                        .contentShape(Rectangle())
                        .onTapGesture { model.editing = item }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { model.delete(item) } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button { model.togglePin(item) } label: {
                                Label(item.pinned ? "取消置顶" : "置顶",
                                      systemImage: item.pinned ? "pin.slash" : "pin")
                            }.tint(.orange)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { model.copy(item) } label: {
                                Label("复制", systemImage: "doc.on.doc")
                            }.tint(.blue)
                        }
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - 行

struct ItemRow: View {
    let item: ClipItem
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if item.pinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundColor(.orange)
                }
                Text(kindLabel)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Spacer()
                Text(LibraryModel.dayFmt.string(from: item.updatedAt))
                    .font(.caption2).foregroundColor(.secondary)
            }
            Text(item.text)
                .font(.callout)
                .lineLimit(3)
                .foregroundColor(.primary)
            Text("\(item.text.count) 字 · \(item.source) · rev\(item.rev)")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button { onCopy() } label: { Label("复制", systemImage: "doc.on.doc") }
        }
    }

    private var kindLabel: String {
        switch item.kind {
        case "url": return "链接"
        case "json": return "JSON"
        case "code": return "代码"
        case "number": return "数字"
        default: return "文本"
        }
    }
}

// MARK: - 编辑

struct EditItemView: View {
    let item: ClipItem
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(item: ClipItem, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.item = item
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: item.text)
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .padding(8)
                Divider()
                HStack {
                    Text("\(text.count) 字")
                    Spacer()
                    Text("rev \(item.rev)")
                }
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .navigationTitle("编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(text) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 设置 / 调试

struct SettingsView: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("统计") {
                    row("条目", "\(model.totalCount)")
                    row("置顶", "\(model.pinnedCount)")
                    row("存储占用", ByteCountFormatter.string(fromByteCount: Int64(model.byteSize), countStyle: .file))
                }

                Section("存储") {
                    row("共享容器", model.isShared ? "✅ App Group" : "⚠️ 私有沙盒（与键盘不互通）")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("路径").font(.caption).foregroundColor(.secondary)
                        Text(model.storagePath)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }

                Section("调试") {
                    row("嵌入的扩展", model.extensionList)
                    row("最近复制", model.lastWrite)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundColor(.secondary)
            Spacer()
            Text(v).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

// MARK: - 分享

struct ShareBox: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
