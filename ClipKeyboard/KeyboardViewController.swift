//
//  KeyboardViewController.swift  —— 极简诊断版（v3-bare）
//
//  目的：把变量降到最少。这段代码不碰 App Group、不碰剪贴板、不起 Timer、
//  不做任何文件 IO，只画一个标签和一个按钮。
//
//  判定：
//    · 这版能切过去 → v2 里有崩溃点，逐步加回功能二分定位
//    · 这版也切不过去 → 问题在签名/系统层，不在代码
//

import UIKit

@objc(KeyboardViewController)
final class KeyboardViewController: UIInputViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = "ClipKeyboard 已加载"
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textAlignment = .center

        let info = UILabel()
        info.text = "极简诊断版 v3：无 App Group / 无剪贴板 / 无定时器"
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabel
        info.numberOfLines = 2
        info.textAlignment = .center

        let next = UIButton(type: .system)
        next.setTitle("切换到下一个键盘", for: .normal)
        next.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        next.backgroundColor = .tertiarySystemBackground
        next.layer.cornerRadius = 6
        next.addTarget(self, action: #selector(goNext), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, info, next])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let height = view.heightAnchor.constraint(equalToConstant: 160)
        height.priority = .defaultHigh

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            next.heightAnchor.constraint(equalToConstant: 36),
            height
        ])
    }

    @objc private func goNext() {
        advanceToNextInputMode()
    }
}
