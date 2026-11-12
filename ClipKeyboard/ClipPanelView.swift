//
//  ClipPanelView.swift
//  键盘内的剪贴板面板：分类条 + 跟随输入过滤 + 列表 + 点选插入 + 常驻重写按钮
//
//  v11：删掉搜不到东西的 UISearchBar。
//  键盘扩展里 UISearchBar 拿不到焦点（扩展本身是键盘，唤不起系统键盘），
//  所以「输入框打字搜索」在这条路上根本走不通。改成两条零输入过滤：
//    1. 分类 chip：全部 / 置顶 / 链接 / JSON / 代码 / 今天 / 长文
//    2. 跟随输入：读宿主输入框光标前的字当作过滤词（用户已经打好的字)
//

import UIKit

final class ClipPanelView: UIView {

    // 回调
    var onPick: ((ClipItem) -> Void)?
    var onRewrite: ((ClipItem, RewriteStep) -> Void)?
    var onPin: ((ClipItem) -> Void)?
    var onDelete: ((ClipItem) -> Void)?
    var onClose: (() -> Void)?
    var onClearQuery: (() -> Void)?

    // 数据
    private var store: ClipStore?
    private var items: [ClipItem] = []
    private var query: String = ""
    private var chip: FilterChip = .all

    // UI
    private let filterBar = UIScrollView()
    private let filterStack = UIStackView()
    private let queryBar = UIView()
    private let queryLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 外部接口

    func bind(store: ClipStore?) {
        self.store = store
        reload()
    }

    /// 由键盘控制器传入「宿主输入框光标前的内容」当作过滤词
    func setContextQuery(_ q: String?) {
        let next = (q ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard next != query else { return }
        query = next
        updateQueryBar()
        reload()
    }

    func reload() {
        var list = store?.visibleItems(limit: 500) ?? []

        switch chip {
        case .all: break
        case .pinned: list = list.filter { $0.pinned }
        case .url:    list = list.filter { $0.kind == "url" }
        case .json:   list = list.filter { $0.kind == "json" }
        case .code:   list = list.filter { $0.kind == "code" }
        case .today:  list = list.filter { Calendar.current.isDateInToday($0.updatedAt) }
        case .long:   list = list.filter { $0.text.count > 200 }
        }

        if !query.isEmpty {
            list = list.filter { Tokenizer.matches($0.text, query: query) }
        }

        items = Array(list.prefix(80))
        tableView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        emptyLabel.text = emptyText()
        updateQueryBar()
    }

    // MARK: - UI

    private func setupUI() {
        // 分类条
        filterBar.showsHorizontalScrollIndicator = false
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filterBar)

        filterStack.axis = .horizontal
        filterStack.spacing = 6
        filterStack.alignment = .center
        filterStack.translatesAutoresizingMaskIntoConstraints = false
        filterBar.addSubview(filterStack)

        for c in FilterChip.allCases {
            let b = UIButton(type: .system)
            b.setTitle(c.title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 11, weight: .medium)
            b.tag = c.rawValue
            b.layer.cornerRadius = 11
            b.contentEdgeInsets = UIEdgeInsets(top: 3, left: 9, bottom: 3, right: 9)
            b.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
            filterStack.addArrangedSubview(b)
        }
        styleChips()

        let close = UIButton(type: .system)
        close.setTitle("收起", for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)

        // 跟随输入提示条
        queryBar.backgroundColor = .tertiarySystemBackground
        queryBar.layer.cornerRadius = 8
        queryBar.isHidden = true
        queryBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(queryBar)

        queryLabel.font = .systemFont(ofSize: 11)
        queryLabel.textColor = .secondaryLabel
        queryLabel.translatesAutoresizingMaskIntoConstraints = false
        queryBar.addSubview(queryLabel)

        let clear = UIButton(type: .system)
        clear.setTitle("✕", for: .normal)
        clear.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
        clear.addTarget(self, action: #selector(clearQuery), for: .touchUpInside)
        clear.translatesAutoresizingMaskIntoConstraints = false
        queryBar.addSubview(clear)

        // 列表
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 56
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        tableView.backgroundColor = .clear
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(ClipCell.self, forCellReuseIdentifier: "cell")
        addSubview(tableView)

        emptyLabel.numberOfLines = 2
        emptyLabel.textAlignment = .center
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabel
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            filterBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            filterBar.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
            filterBar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            filterBar.heightAnchor.constraint(equalToConstant: 26),

            filterStack.leadingAnchor.constraint(equalTo: filterBar.leadingAnchor),
            filterStack.trailingAnchor.constraint(equalTo: filterBar.trailingAnchor),
            filterStack.topAnchor.constraint(equalTo: filterBar.topAnchor),
            filterStack.heightAnchor.constraint(equalTo: filterBar.heightAnchor),

            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: filterBar.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 40),

            queryBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            queryBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            queryBar.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 4),
            queryBar.heightAnchor.constraint(equalToConstant: 22),

            queryLabel.leadingAnchor.constraint(equalTo: queryBar.leadingAnchor, constant: 8),
            queryLabel.centerYAnchor.constraint(equalTo: queryBar.centerYAnchor),
            queryLabel.trailingAnchor.constraint(lessThanOrEqualTo: queryBar.trailingAnchor, constant: -26),

            clear.trailingAnchor.constraint(equalTo: queryBar.trailingAnchor, constant: -6),
            clear.centerYAnchor.constraint(equalTo: queryBar.centerYAnchor),
            clear.widthAnchor.constraint(equalToConstant: 20),

            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.topAnchor.constraint(equalTo: queryBar.bottomAnchor, constant: 2),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8)
        ])
    }

    private func styleChips() {
        for case let b as UIButton in filterStack.arrangedSubviews {
            let active = b.tag == chip.rawValue
            b.backgroundColor = active ? .systemBlue : .tertiarySystemBackground
            b.setTitleColor(active ? .white : .label, for: .normal)
        }
    }

    private func updateQueryBar() {
        let show = !query.isEmpty
        queryBar.isHidden = !show
        guard show else { return }
        let hit = items.count
        queryLabel.text = "跟随输入：\(query)  ·  \(hit) 条"
    }

    private func emptyText() -> String {
        if !query.isEmpty { return "没有匹配「\(query)」的记录" }
        switch chip {
        case .all: return "还没有剪贴板记录\n复制点什么，再切回来"
        case .pinned: return "没有置顶条目\n长按一条可以置顶"
        case .url: return "没有链接类记录"
        case .json: return "没有 JSON 记录"
        case .code: return "没有代码类记录"
        case .today: return "今天还没有新记录"
        case .long: return "没有 200 字以上的长文"
        }
    }

    @objc private func closeTapped() { onClose?() }

    @objc private func clearQuery() { onClearQuery?() }

    @objc private func chipTapped(_ sender: UIButton) {
        guard let c = FilterChip(rawValue: sender.tag) else { return }
        chip = c
        styleChips()
        reload()
    }

    // MARK: - 重写菜单

    func menu(for item: ClipItem) -> UIMenu? {
        let options = Rewriter.options(for: item.text)
        guard !options.isEmpty else { return nil }

        let recOps = Rewriter.candidates(for: item.text).map { $0.op }
        var recommended: [UIAction] = []
        for op in recOps {
            guard let hit = options.first(where: { $0.op == op }) else { continue }
            recommended.append(action(item, hit, icon: "wand.and.stars"))
        }

        var children: [UIMenuElement] = []
        if !recommended.isEmpty {
            children.append(UIMenu(title: "推荐", options: .displayInline, children: recommended))
        }

        for section in ["编码", "文本", "哈希"] {
            let acts = options
                .filter { $0.op.section == section && !recOps.contains($0.op) }
                .map { action(item, $0, icon: $0.op.iconName) }
            guard !acts.isEmpty else { continue }
            children.append(UIMenu(title: section, options: .displayInline, children: acts))
        }

        guard !children.isEmpty else { return nil }
        return UIMenu(children: children)
    }

    private func action(_ item: ClipItem, _ option: Rewriter.Option, icon: String) -> UIAction {
        let title = "\(option.title)  \(option.detail)"
        return UIAction(title: title, image: UIImage(systemName: icon)) { [weak self] _ in
            self?.onRewrite?(item, option.step)
        }
    }

    private func rowMenu(for item: ClipItem) -> UIMenu {
        let pin = UIAction(
            title: item.pinned ? "取消置顶" : "置顶",
            image: UIImage(systemName: item.pinned ? "pin.slash" : "pin")
        ) { [weak self] _ in self?.onPin?(item) }

        let del = UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.onDelete?(item)
        }

        var children: [UIMenuElement] = []
        if let rewrite = menu(for: item) {
            children.append(rewrite)
        }
        children.append(contentsOf: [pin, del])
        return UIMenu(children: children)
    }
}

// MARK: - 分类

enum FilterChip: Int, CaseIterable {
    case all = 0, pinned, url, json, code, today, long

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

// MARK: - TableView

extension ClipPanelView: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! ClipCell
        let item = items[indexPath.row]
        cell.configure(with: item, query: query)

        cell.rewriteButton.menu = menu(for: item)
        cell.rewriteButton.showsMenuAsPrimaryAction = true
        cell.rewriteButton.isEnabled = cell.rewriteButton.menu != nil
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        onPick?(items[indexPath.row])
    }

    func tableView(_ tableView: UITableView,
                   contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        let item = items[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.rowMenu(for: item)
        }
    }
}

// MARK: - Cell

final class ClipCell: UITableViewCell {

    private let previewLabel = UILabel()
    private let metaLabel = UILabel()
    private let pinIcon = UIImageView(image: UIImage(systemName: "pin.fill"))
    let rewriteButton = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear

        previewLabel.numberOfLines = 2
        previewLabel.font = .systemFont(ofSize: 13)
        previewLabel.translatesAutoresizingMaskIntoConstraints = false

        metaLabel.font = .systemFont(ofSize: 10)
        metaLabel.textColor = .tertiaryLabel
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        pinIcon.tintColor = .systemBlue
        pinIcon.contentMode = .scaleAspectFit
        pinIcon.translatesAutoresizingMaskIntoConstraints = false
        pinIcon.isHidden = true

        rewriteButton.setImage(UIImage(systemName: "wand.and.stars"), for: .normal)
        rewriteButton.tintColor = .systemBlue
        rewriteButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(previewLabel)
        contentView.addSubview(metaLabel)
        contentView.addSubview(pinIcon)
        contentView.addSubview(rewriteButton)

        NSLayoutConstraint.activate([
            rewriteButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            rewriteButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            rewriteButton.widthAnchor.constraint(equalToConstant: 40),
            rewriteButton.heightAnchor.constraint(equalToConstant: 40),

            previewLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            previewLabel.trailingAnchor.constraint(equalTo: rewriteButton.leadingAnchor, constant: -6),
            previewLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),

            metaLabel.leadingAnchor.constraint(equalTo: previewLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 2),
            metaLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -6),

            pinIcon.trailingAnchor.constraint(equalTo: previewLabel.trailingAnchor, constant: -2),
            pinIcon.centerYAnchor.constraint(equalTo: metaLabel.centerYAnchor),
            pinIcon.widthAnchor.constraint(equalToConstant: 12),
            pinIcon.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with item: ClipItem, query: String) {
        previewLabel.text = item.preview
        pinIcon.isHidden = !item.pinned

        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        var meta = "\(item.kind) · \(f.string(from: item.updatedAt))"
        if item.text.count > 120 { meta += " · \(item.text.count) 字" }
        metaLabel.text = meta
    }
}
