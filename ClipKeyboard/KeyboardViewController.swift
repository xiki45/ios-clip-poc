//
//  KeyboardViewController.swift
//  剪贴板键盘：采集 + 分类面板 + 跟随输入过滤 + 点选插入 + 规则重写
//
//  采集时机：键盘可见期间轮询 changeCount（iOS 不允许后台读剪贴板，
//  所以「打开键盘才采集」是这个平台上唯一可行的模式）。
//
//  过滤时机：键盘扩展无法在自身 UI 里调起系统键盘，所以「打字搜索」这条路走不通；
//  改成读宿主输入框光标前的内容当过滤词——用户用别的键盘打好的字，切过来就能用。
//

import UIKit

@objc(KeyboardViewController)
final class KeyboardViewController: UIInputViewController {

    // 数据
    private var store: ClipStore?
    private var lastChangeCount = -1

    // 跟随输入的过滤词
    private var lastContextWord: String?
    private var suppressedFor: String?
    private var ignoreNextContextRefresh = false

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
        panel.onClearQuery = { [weak self] in
            guard let self else { return }
            self.suppressedFor = self.lastContextWord
            self.panel.setContextQuery(nil)
            self.updateStatus("已清除过滤")
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        capture()
        refreshContextQuery()
        startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// 宿主输入框内容变化（用户打字 / 光标移动）时被调用
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if ignoreNextContextRefresh {
            ignoreNextContextRefresh = false
            return
        }
        refreshContextQuery()
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

    // MARK: - 跟随输入的过滤词

    private func refreshContextQuery() {
        let word = contextWord()
        lastContextWord = word

        // 用户点过 ✕：只要光标前的词没变，就别再自动填回去
        if let s = suppressedFor {
            if s == word {
                panel.setContextQuery(nil)
                return
            }
            suppressedFor = nil
        }

        panel.setContextQuery(word)
    }

    /// 取宿主输入框「光标前最后一个词」，太长就截尾
    private func contextWord() -> String? {
        guard let ctx = textDocumentProxy.documentContextBeforeInput, !ctx.isEmpty else { return nil }
        let stop = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)

        var chars = Array(ctx)
        var end = chars.count
        while end > 0, let u = chars[end - 1].unicodeScalars.first, stop.contains(u) { end -= 1 }
        var start = end
        while start > 0, let u = chars[start - 1].unicodeScalars.first, !stop.contains(u) { start -= 1 }
        guard end > start else { return nil }

        var word = String(chars[start..<end])
        if word.count > 8 { word = String(word.suffix(8)) }

        // 单字符只有中文值得拿来过滤，单字母会命中一切
        if word.count == 1 {
            guard let c = word.first, Tokenizer.isCJK(c) else { return nil }
        }
        return word
    }

    // MARK: - 动作

    private func insert(_ item: ClipItem) {
        ignoreNextContextRefresh = true
        textDocumentProxy.insertText(item.text)
        updateStatus("已插入 \(item.text.count) 字")
    }

    private func rewrite(_ item: ClipItem, _ step: RewriteStep) {
        let result = Rewriter.apply(item.text, steps: [step])
        guard result.ok else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            updateStatus("\(step.op.displayName)失败：\(result.error ?? "未知原因")")
            return
        }
        ignoreNextContextRefresh = true
        textDocumentProxy.insertText(result.output)
        // 重写结果存一条，便于二次使用（同内容会命中去重，只更新时间戳）
        store?.upsert(result.output, source: "rewrite")
        panel.reload()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        updateStatus("\(step.op.displayName) → 已插入 \(result.output.count) 字")
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

        let height = view.heightAnchor.constraint(equalToConstant: 296)
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
