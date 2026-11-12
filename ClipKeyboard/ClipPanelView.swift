//
//  ClipPanelView.swift
//  键盘内的剪贴板面板：搜索 + 列表 + 点选插入 + 长按菜单（规则/置顶/删除）
//

import UIKit

final class ClipPanelView: UIView {

    // 回调
    var onPick: ((ClipItem) -> Void)?
    var onRewrite: ((ClipItem, RewriteStep) -> Void)?
    var onPin: ((ClipItem) -> Void)?
    var onDelete: ((ClipItem) -> Void)?
    var onClose: (() -> Void)?

    // 数据
    private var store: ClipStore?
    private var items: [ClipItem] = []
    private var query: String = ""

    // UI
    private let searchBar = UISearchBar()
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

    func reload() {
        let filtered = store?.search(query) ?? []
        items = Array(filtered.prefix(80))
        tableView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
    }

    // MARK: - UI

    private func setupUI() {
        searchBar.placeholder = "搜索剪贴板"
        searchBar.searchBarStyle = .minimal
        searchBar.delegate = self
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchBar)

        let close = UIButton(type: .system)
        close.setTitle("收起", for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 54
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        tableView.backgroundColor = .clear
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(ClipCell.self, forCellReuseIdentifier: "cell")
        addSubview(tableView)

        emptyLabel.text = "还没有剪贴板记录\n复制点什么，再切回来"
        emptyLabel.numberOfLines = 2
        emptyLabel.textAlignment = .center
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabel
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            searchBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            searchBar.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
            searchBar.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            searchBar.heightAnchor.constraint(equalToConstant: 36),

            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 40),

            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 2),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8)
        ])
    }

    @objc private func closeTapped() { onClose?() }

    // MARK: - 规则菜单

    private func menu(for item: ClipItem) -> UIMenu {
        var actions: [UIAction] = []

        // 自动识别出的候选
        for step in Rewriter.candidates(for: item.text) {
            let result = Rewriter.apply(item.text, steps: [step])
            guard result.ok else { continue }
            let title = "\(step.op.displayName) → \(String(result.output.prefix(18)))"
            actions.append(UIAction(title: title, image: UIImage(systemName: "wand.and.stars")) { [weak self] _ in
                self?.onRewrite?(item, step)
            })
        }

        // 固定几个常用
        for op in [RewriteOp.urlDecode, .jsonPretty, .dedupeLines] where !actions.contains(where: { $0.title.hasPrefix(op.displayName) }) {
            actions.append(UIAction(title: op.displayName, image: UIImage(systemName: "text.badge.checkmark")) { [weak self] _ in
                self?.onRewrite?(item, RewriteStep(op))
            })
        }

        let rewriteMenu = UIMenu(title: "重写内容", children: actions)

        let pin = UIAction(
            title: item.pinned ? "取消置顶" : "置顶",
            image: UIImage(systemName: item.pinned ? "pin.slash" : "pin")
        ) { [weak self] _ in self?.onPin?(item) }

        let del = UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.onDelete?(item)
        }

        return UIMenu(children: [rewriteMenu, pin, del])
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
            self?.menu(for: item)
        }
    }
}

// MARK: - 搜索

extension ClipPanelView: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        query = searchText
        reload()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

// MARK: - Cell

final class ClipCell: UITableViewCell {

    private let previewLabel = UILabel()
    private let metaLabel = UILabel()
    private let pinIcon = UIImageView(image: UIImage(systemName: "pin.fill"))

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

        contentView.addSubview(previewLabel)
        contentView.addSubview(metaLabel)
        contentView.addSubview(pinIcon)

        NSLayoutConstraint.activate([
            previewLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            previewLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -30),
            previewLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),

            metaLabel.leadingAnchor.constraint(equalTo: previewLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 2),
            metaLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -6),

            pinIcon.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            pinIcon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
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
