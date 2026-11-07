//
//  KeyboardViewController.swift
//  ClipKeyboard
//
//  POC 2 的全部验证都在这里：
//   ① 键盘进程能否读写 App Group 容器（POC 1 的另一半）
//   ② 键盘侧读 UIPasteboard 是否成功（Full Access 是否真正生效）
//   ③ 键盘关闭后扩展是否被挂起（心跳停止即挂起，属正常行为）
//   ④ 能否通过 textDocumentProxy 把内容插入宿主输入框（后续产品的上屏通道）
//

import UIKit

final class KeyboardViewController: UIInputViewController {

    // MARK: - UI

    private let statusLabel = UILabel()
    private let logLabel = UILabel()
    private let headerStack = UIStackView()

    // MARK: - 状态

    private var heartbeatTimer: Timer?
    private var tick = 0
    private var appearedAt = Date()
    private var lines: [String] = []

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        GroupStore.append(PocLogEntry(source: "keyboard", event: "kb_load",
                                      detail: "container=\(GroupStore.containerURL?.path ?? "nil")"))
        reloadStatus()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        appearedAt = Date()
        log("kb_will_appear", "shared=\(GroupStore.effectiveDirectory?.isShared == true)")
        startHeartbeat()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 键盘出现后立刻做一次剪贴板探测，最接近真实产品行为
        probePasteboard(reason: "on_appear")
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopHeartbeat()
        GroupStore.append(PocLogEntry(source: "keyboard", event: "kb_hide",
                                      detail: "alive=\(Int(Date().timeIntervalSince(appearedAt)))s"))
        GroupStore.writeHeartbeat([
            "ts": Date().timeIntervalSince1970,
            "source": "keyboard",
            "state": "hidden",
            "alive_seconds": Int(Date().timeIntervalSince(appearedAt))
        ])
    }

    // MARK: - 心跳

    private func startHeartbeat() {
        stopHeartbeat()
        tick = 0
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick += 1
            GroupStore.writeHeartbeat([
                "ts": Date().timeIntervalSince1970,
                "source": "keyboard",
                "state": "visible",
                "tick": self.tick,
                "alive_seconds": Int(Date().timeIntervalSince(self.appearedAt)),
                "shared": GroupStore.effectiveDirectory?.isShared == true
            ])
            if self.tick % 15 == 0 {
                self.log("kb_heartbeat", "tick=\(self.tick)")
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - 动作

    @objc private func writeFromKeyboard() {
        let batch = (1...5).map {
            PocLogEntry(source: "keyboard", event: "group_write",
                        detail: "kb-batch #\($0) dir=\(GroupStore.effectiveDirectory?.isShared == true ? "group" : "private")")
        }
        GroupStore.appendBulk(batch)
        flash("已写入 5 条")
        reloadStatus()
    }

    @objc private func readPasteboard() {
        probePasteboard(reason: "manual")
        flash("已探测，详见日志")
    }

    @objc private func insertSample() {
        let text = "「来自 ClipKeyboard」"
        textDocumentProxy.insertText(text)
        log("kb_insert", "text=\(text)")
        flash("已插入测试文本")
    }

    @objc private func nextKeyboard() {
        advanceToNextInputMode()
    }

    /// 剪贴板探测：把“能不能读”与“读到什么”分开记录，便于判断是权限问题还是内容问题
    private func probePasteboard(reason: String) {
        let pb = UIPasteboard.general
        let hasStrings = pb.hasStrings
        let changeCount = pb.changeCount
        let began = Date()
        let value = pb.string
        let costMS = Int(Date().timeIntervalSince(began) * 1000)

        let detail: String
        if let v = value {
            detail = "reason=\(reason) hasStrings=\(hasStrings) len=\(v.count) cost=\(costMS)ms preview=\(String(v.prefix(40)))"
        } else {
            detail = "reason=\(reason) hasStrings=\(hasStrings) len=nil cost=\(costMS)ms ← 读不到内容"
        }

        GroupStore.append(PocLogEntry(source: "keyboard", event: "pasteboard_kb", detail: detail))
        log("pasteboard", "hasStrings=\(hasStrings) changeCount=\(changeCount) len=\(value?.count ?? -1)")
        reloadStatus()
    }

    // MARK: - UI 构建

    private func buildUI() {
        view.backgroundColor = .secondarySystemBackground

        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.numberOfLines = 3
        statusLabel.textColor = .secondaryLabel

        logLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        logLabel.numberOfLines = 6
        logLabel.textColor = .tertiaryLabel

        let title = UILabel()
        title.text = "ClipKeyboard · POC"
        title.font = .systemFont(ofSize: 12, weight: .semibold)

        let buttons = [
            makeButton("键盘写入", action: #selector(writeFromKeyboard)),
            makeButton("读剪贴板", action: #selector(readPasteboard)),
            makeButton("插入文本", action: #selector(insertSample)),
            makeButton("切键盘", action: #selector(nextKeyboard))
        ]

        let buttonRow = UIStackView(arrangedSubviews: buttons)
        buttonRow.axis = .horizontal
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 6

        let stack = UIStackView(arrangedSubviews: [title, statusLabel, buttonRow, logLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        // 键盘高度：用低优先级的固定高度，避免与系统容器约束硬冲突
        let height = view.heightAnchor.constraint(equalToConstant: 230)
        height.priority = .defaultHigh

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -8),
            height
        ])
    }

    private func makeButton(_ title: String, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        b.backgroundColor = .tertiarySystemBackground
        b.layer.cornerRadius = 6
        b.addTarget(self, action: action, for: .touchUpInside)
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return b
    }

    // MARK: - 状态展示

    private func reloadStatus() {
        let shared = GroupStore.effectiveDirectory?.isShared == true
        let dir = GroupStore.effectiveDirectory?.url.path ?? "nil"
        statusLabel.text = """
        group: \(shared ? "共享 ✅" : "私有 ❌")  \(GroupStore.groupID)
        dir: \(dir)
        pid: \(ProcessInfo.processInfo.processIdentifier)
        """
        logLabel.text = lines.suffix(6).joined(separator: "\n")
    }

    private func log(_ event: String, _ detail: String) {
        let line = "\(timeString()) \(event) \(detail)"
        lines.append(line)
        if lines.count > 40 { lines.removeFirst() }
        GroupStore.append(PocLogEntry(source: "keyboard", event: event, detail: detail))
        DispatchQueue.main.async { self.reloadStatus() }
    }

    private func timeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    private func flash(_ text: String) {
        let original = statusLabel.text
        statusLabel.text = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.statusLabel.text = original }
    }
}
