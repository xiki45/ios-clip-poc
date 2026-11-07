//
//  AppModel.swift
//  PocApp
//
//  主 App 侧的验证面板：POC1（App Group）、POC2（键盘是否在写）、POC3（后台存活）。
//

import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {

    @Published var report: String = ""
    @Published var verdict: String = ""
    @Published var entries: [PocLogEntry] = []
    @Published var keyboardHeartbeat: String = "（尚未收到键盘心跳）"
    @Published var lastKeyboardSeen: String = "—"
    @Published var backgroundRunning = false
    @Published var backgroundElapsed: Int = 0
    @Published var backgroundRemaining: String = "—"
    @Published var toast: String = ""

    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var bgTimer: Timer?
    private var refreshTimer: Timer?
    private var bgStartedAt: Date?

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - 刷新

    func refresh() {
        report = Diagnostics.report(source: "app")
        verdict = Diagnostics.verdict(source: "app")
        entries = GroupStore.readAll(limit: 200).reversed().map { $0 }

        let hb = GroupStore.readHeartbeat()
        if !hb.isEmpty {
            keyboardHeartbeat = hb.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
            if let ts = hb["ts"] as? Double {
                let d = Date(timeIntervalSince1970: ts)
                lastKeyboardSeen = "\(Self.fmt.string(from: d))（\(Int(Date().timeIntervalSince(d)))s 前）"
            }
        } else {
            keyboardHeartbeat = "（尚未收到键盘心跳）"
            lastKeyboardSeen = "—"
        }

        if backgroundRunning {
            backgroundElapsed = Int(Date().timeIntervalSince(bgStartedAt ?? Date()))
            let r = UIApplication.shared.backgroundTimeRemaining
            backgroundRemaining = r.isFinite ? String(format: "%.0fs", r) : "∞（可能已被特权签名放行）"
        }
    }

    // MARK: - POC 1：App 侧写入

    func writeFromApp() {
        let batch = (1...10).map {
            PocLogEntry(source: "app", event: "group_write",
                        detail: "app-batch #\($0) @\(Self.fmt.string(from: Date()))")
        }
        GroupStore.appendBulk(batch)
        toast = "已写入 10 条（\(GroupStore.effectiveDirectory?.isShared == true ? "App Group" : "私有沙盒")）"
        refresh()
    }

    func clearLog() {
        GroupStore.clear()
        toast = "日志已清空"
        refresh()
    }

    // MARK: - POC 3：后台存活

    func toggleBackgroundHeartbeat() {
        backgroundRunning ? stopBackground() : startBackground()
    }

    private func startBackground() {
        guard !backgroundRunning else { return }
        bgStartedAt = Date()
        backgroundElapsed = 0
        backgroundRunning = true

        bgTask = UIApplication.shared.beginBackgroundTask(withName: "poc-heartbeat") { [weak self] in
            Task { @MainActor in
                self?.appendBG(event: "bg_expired", detail: "系统即将终止后台任务")
                self?.stopBackground()
            }
        }

        appendBG(event: "bg_start", detail: "beginBackgroundTask 返回 \(bgTask.rawValue)")

        bgTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let elapsed = Int(Date().timeIntervalSince(self.bgStartedAt ?? Date()))
                self.appendBG(event: "bg_heartbeat", detail: "elapsed=\(elapsed)s")
                GroupStore.writeHeartbeat([
                    "ts": Date().timeIntervalSince1970,
                    "source": "app-bg",
                    "elapsed": elapsed
                ])
            }
        }
    }

    private func stopBackground() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        bgTimer?.invalidate()
        bgTimer = nil
        backgroundRunning = false
    }

    private func appendBG(event: String, detail: String) {
        let r = UIApplication.shared.backgroundTimeRemaining
        let remain = r.isFinite ? String(format: "%.1f", r) : "inf"
        GroupStore.append(PocLogEntry(source: "app", event: event,
                                      detail: "\(detail); bgRemaining=\(remain)"))
    }

    // MARK: - 辅助

    func copyTestText() {
        let text = "POC-TEXT-\(Int(Date().timeIntervalSince1970)) 你好 base64 aGVsbG8="
        UIPasteboard.general.string = text
        toast = "已写入系统剪贴板：\(text)"
    }

    /// 主 App 读剪贴板（对照组：前台 App 应始终可读）
    func readPasteboardFromApp() {
        let s = UIPasteboard.general.string ?? "nil"
        GroupStore.append(PocLogEntry(source: "app", event: "pasteboard_app",
                                      detail: "len=\(s.count) changeCount=\(UIPasteboard.general.changeCount) preview=\(String(s.prefix(60)))"))
        toast = "App 读到：\(s.prefix(40))…"
        refresh()
    }

    /// 扩展是否被嵌进 App（未嵌则设置里看不到键盘）
    var embeddedExtension: String {
        guard let url = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return "未找到 PlugIns 目录"
        }
        let names = items.map { $0.lastPathComponent }
        return names.isEmpty ? "PlugIns 为空（扩展没嵌进来）" : names.joined(separator: ", ")
    }

    static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
