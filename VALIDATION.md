# 交付自检报告

> 生成时间：2026-11-07
> 构建机：macOS + Command Line Tools only（无 Xcode）→ 已改用 GitHub Actions 云端构建，产物见 README §0

## 0. 为什么本机编不出 IPA（事实）

```
$ ls /Library/Developer/CommandLineTools/SDKs
MacOSX.sdk  MacOSX14.5.sdk  MacOSX14.sdk  MacOSX15.2.sdk  MacOSX15.sdk     ← 只有 macOS SDK
$ xcodebuild -version
xcode-select: error: tool 'xcodebuild' requires Xcode
$ swift --version
Apple Swift version 6.0.3
```

- Swift 编译器在，但**没有 `iPhoneOS.sdk`**，链接不出 arm64-apple-ios 的二进制；
- `xcodebuild` 也不存在（它不是 CLT 的一部分）。

**结论：本机不可能产出 IPA。**需要 Xcode（约 10 GB+）或一台带 Xcode 的机器/CI。

## 1. 本机已实跑并通过的验证

| # | 验证 | 命令 | 结果 |
|---|---|---|---|
| 1 | 6 个 Swift 文件语法解析 | `swiftc -frontend -parse -swift-version 5 <file>` | ✅ 6/6 无输出 |
| 2 | Shared 层**完整类型检查**（GroupStore + Diagnostics） | `swiftc -typecheck -swift-version 5 -sdk $(xcrun --show-sdk-path) Shared/*.swift` | ✅ exit=0 |
| 3 | pbxproj OpenStep 语法 | `plutil -lint PocApp.xcodeproj/project.pbxproj` | ✅ OK，且可转 XML |
| 4 | 4 个 plist/entitlements | `plutil -lint` ×4 | ✅ OK |
| 5 | App Group 三处一致 | 交叉比对 | ✅ `group.com.ouo.clipboardpoc` |
| 6 | Bundle ID 前缀关系 | 解析 pbxproj | ✅ `com.ouo.clipboardpoc{,.keyboard}` |
| 7 | 键盘扩展声明 | 解析 Info.plist | ✅ `com.apple.keyboard-service`、`RequestsOpenAccess=YES` |
| 8 | pbxproj UUID | 正则 + 引用闭包 | ✅ 48 个 24 位 hex，无悬空引用 |
| 9 | Swift 括号平衡 | 计数 | ✅ 6/6 |

> 第 2 项含金量最高：`GroupStore` 的文件 IO / JSONL 追加 / 心跳写读，以及 `Diagnostics` 的 `dlsym` + `SecTask*` 动态调用，**都过了真实类型检查**（Foundation/Security/Darwin 在 macOS 与 iOS 上 API 一致）。

## 2. 本机无法验证的部分

| 项 | 原因 | 风险 |
|---|---|---|
| `PocApp` / `ClipKeyboard` 的 UIKit / SwiftUI 类型检查 | 缺 iOS SDK（UIKit 在 macOS 不存在） | 中 |
| 整体链接与产物结构 | 同上 | 中 |
| 真机加载扩展、App Group 生效 | 需设备 | **高（这正是 POC 要回答的）** |

这几项只能靠：**装 Xcode 在本机构建**，或 **推 GitHub Actions（已在 `.github/workflows/build-ipa.yml` 配好）**。

## 3. 已知设计取舍

- `CODE_SIGNING_ALLOWED = NO`：无证书也能编译，签名交给 `ldid`。
- 扩展 principal class 用 `$(PRODUCT_MODULE_NAME).KeyboardViewController`，因此**不能**给类加 `@objc(...)` 重命名（会改变运行时类名导致解析失败）。
- `AppModel` 不用 `deinit` 清理 Timer（Swift 5.9 下 `@MainActor` 隔离会在 `deinit` 报错），靠 `[weak self]` 防循环引用。
- 键盘高度用 `.defaultHigh` 优先级，避免与系统容器约束硬冲突。

## 4. 最小验证路径（10 分钟）

1. 装 IPA → 打开 App → 看「结论」是否 `✅ POC1 通过`
2. 点「App 写入 10 条」
3. 输入框切到 ClipKeyboard → 看是否 `group: 共享 ✅`
4. 点「键盘写入」→ 回 App → 出现**绿色 keyboard 记录**

第 4 步出现绿色记录 = App Group 打通 = iOS 方案地基成立。
