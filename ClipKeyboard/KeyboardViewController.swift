//
//  KeyboardViewController.swift
//  剪贴板键盘 v1：采集 + 面板 + 点选插入 + 规则重写
//
//  采集时机：键盘可见期间轮询 changeCount（iOS 不允许后台读剪贴板，
//  所以「打开键盘才采集」是这个平台上唯一可行的模式）。
//

import UIKit

@objc(KeyboardViewController)
final class KeyboardViewController: UIInputViewController {

    // 数据
    private var store: ClipStore?
    private var lastChangeCount = -1

    // UI
    private let panel = ClipPanelView()
    private let toolbar = UIView()
    private let statusLabel = UILabel()
    private var pollTimer: Timer?

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()

        let dir = GroupStore.containerURL ?? GroupStore.privateDocumentsURL
        if let dir {
            store = ClipStore(directory: dir)
        }

        buildUI()
        panel.bind(store: store)
        panel.onPick = { [weak self] item in self?.insert(item) }
        panel.onRewrite = { [weak self] item, step in self?.rewrite(item, step) }
        panel.onPin = { [weak self] item in
            self?.store?.togglePin(id: item.id)
            self?.panel.reload()
        }
        panel.onDelete = { [weak self] item in
            self?.store?.remove(id: item.id)
            self?.panel.reload()
        }
        panel.onClose = { [weak self] in self?.advanceToNextInputMode() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        capture()
        startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - 采集

    private func capture() {
        let pb = UIPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let text = pb.string, !text.isEmpty else { return }
        store?.upsert(text, source: "keyboard")
        panel.reload()
        updateStatus("已记录 \(store?.visibleItems().count ?? 0) 条")
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.capture()
        }
    }

    // MARK: - 动作

    private func insert(_ item: ClipItem) {
        textDocumentProxy.insertText(item.text)
        updateStatus("已插入 \(item.text.count) 字")
    }

    private func rewrite(_ item: ClipItem, _ step: RewriteStep) {
        let result = Rewriter.apply(item.text, steps: [step])
        guard result.ok else {
            updateStatus(result.error ?? "重写失败")
            return
        }
        textDocumentProxy.insertText(result.output)
        // 重写结果也存一条，便于二次使用
        store?.upsert(result.output, source: "keyboard")
        panel.reload()
        updateStatus("\(step.op.displayName) → 已插入")
    }

    // MARK: - UI

    private func buildUI() {
        view.backgroundColor = .secondarySystemBackground

        toolbar.backgroundColor = .tertiarySystemBackground
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)

        let clipButton = makeButton("剪贴板", icon: "doc.on.clipboard")
        clipButton.addTarget(self, action: #selector(showPanel), for: .touchUpInside)

        let nextButton = makeButton("键盘", icon: "keyboard")
        nextButton.addTarget(self, action: #selector(goNext), for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [clipButton, statusLabel, nextButton])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(row)

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        let height = view.heightAnchor.constraint(equalToConstant: 268)
        height.priority = .defaultHigh

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 36),

            row.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            height
        ])

        updateStatus("就绪")
    }

    private func makeButton(_ title: String, icon: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(" " + title, for: .normal)
        b.setImage(UIImage(systemName: icon), for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        b.tintColor = .label
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private func updateStatus(_ text: String) {
        statusLabel.text = text
    }

    @objc private func showPanel() {
        panel.isHidden.toggle()
        panel.reload()
    }

    @objc private func goNext() {
        advanceToNextInputMode()
    }
}
