# 用 GitHub Actions 云端构建 IPA（本机无 Xcode）

> 产物：未签名 + entitlements 已写入的 `PocApp.ipa`，TrollStore 直接装。
> 耗时：一次构建约 3~6 分钟。费用：公开仓库免费；私有仓库按 macOS 10× 计费（约消耗 30~60 分钟额度）。

---

## 0. 前置

- 一个 GitHub 账号
- 本机 `git`（已有）
- 可选：`gh` CLI（`brew install gh`）能少点网页操作

---

## 1. 建仓库

**方式 A：网页**
1. https://github.com/new → 名字随意（如 `ios-clip-poc`）→ **不要**勾选 README / .gitignore（否则首次 push 冲突）
2. 记下地址，如 `git@github.com:你的用户名/ios-clip-poc.git`

**方式 B：gh CLI**

```bash
cd "/Users/ouo/Documents/deepseek_workspace/2026-11-05T19:18-mobile-ime-research/tasks/ios-poc-appgroup/output"
gh repo create ios-clip-poc --private --source=. --push
# 这条命令会自动 init + commit + push，跳过第 2 步
```

---

## 2. 初始化并推送

```bash
cd "/Users/ouo/Documents/deepseek_workspace/2026-11-05T19:18-mobile-ime-research/tasks/ios-poc-appgroup/output"

git init -b main
git add .
git commit -m "iOS clipboard POC: app group + keyboard extension"
git remote add origin git@github.com:你的用户名/ios-clip-poc.git
git push -u origin main
```

> 用 HTTPS 就换成 `https://github.com/你的用户名/ios-clip-poc.git`
> 首次 push 若要认证，用 Personal Access Token 当密码，或先 `gh auth login`。

**推送后会自动触发一次构建**（workflow 配了 `push: branches: [main, master]`）。

---

## 3. 看构建 / 手动重跑

- 网页：仓库 → **Actions** → `build-ipa` → 最近一次运行
- 手动触发：Actions → 左侧 `build-ipa` → 右侧 **Run workflow** → 选 `main` → Run

**每个步骤在干什么**

| 步骤 | 作用 |
|---|---|
| 工具链信息 | 打印 Xcode 版本、iOS SDK 版本、target 列表（排错第一现场） |
| 编译（未签名） | `xcodebuild -target PocApp -sdk iphoneos CODE_SIGNING_ALLOWED=NO` |
| 检查产物结构 | 断言 `PocApp.app/PlugIns/ClipKeyboard.appex` 存在，并打印目录树 |
| 签名并打包 | `codesign --force --sign -` 先签 appex 再签 App，回读 entitlements 并断言 group id 存在 |
| 打包 IPA | `Payload/PocApp.app` → `PocApp.ipa` |
| 上传 IPA | artifact `PocApp-ipa`（保留 14 天） |
| 失败时上传日志 | artifact `build-log`，含完整 xcodebuild 输出 |

---

## 4. 下载并安装

1. 构建页底部 **Artifacts** → 下载 `PocApp-ipa`（是个 zip）
2. 解压得到 `PocApp.ipa` + 两个 `check-*-entitlements.plist`
3. 先看 `check-app-entitlements.plist` / `check-ext-entitlements.plist`，里面应各有：
   ```xml
   <key>com.apple.security.application-groups</key>
   <array><string>group.com.ouo.clipboardpoc</string></array>
   ```
   **如果这里没有 group id，就别急着装**——说明 ldid 没生效，装了 App Group 也必然是 nil。
4. 传到手机（AirDrop / 文件 App / 局域网），TrollStore 打开安装
5. 按 `docs/POC-CHECKLIST.md` 验证

---

## 5. 常见失败与对应改法

| Actions 报错 | 原因 | 改法 |
|---|---|---|
| `xcodebuild: error: Unable to find a destination` | runner 上 Xcode 版本差异 | 把 `-sdk iphoneos` 换成 `-destination 'generic/platform=iOS'` |
| `error: Signing for "ClipKeyboard" requires a development team` | `CODE_SIGNING_ALLOWED=NO` 没传到扩展 | 确认 build settings 里两个 target 都有该设置（工程里已写死） |
| `No such file: build/Release-iphoneos/PocApp.app` | SYMROOT 路径没生效 | 看 `xcodebuild -list` 与实际输出；可改用 `-derivedDataPath build` |
| `扩展没有被嵌入` | Embed App Extensions 阶段缺失 | 检查 pbxproj 的 `dstSubfolderSpec = 13` 与 `ClipKeyboard.appex in Embed App Extensions` |
| `ldid: command not found` 且 codesign 也失败 | brew 安装受限 | 手动 `brew install ldid` 后重跑；或改用 `codesign --force --sign -` |
| `The requested URL returned error: 403` | 私有仓库额度耗尽 | 改成公开仓库，或等下月额度 |

**遇到任何失败**：把 `build-log` artifact 里 `xcodebuild` 报错那 20 行贴回来，我直接改工程。

---

## 6. 为什么不直接在本地构建

本机只有 Command Line Tools：

```
/Library/Developer/CommandLineTools/SDKs/
  MacOSX.sdk  MacOSX14.5.sdk  MacOSX14.sdk  MacOSX15.2.sdk  MacOSX15.sdk
```

没有 `iPhoneOS.sdk`，也没有 `xcodebuild`，链不出 iOS 二进制。GitHub 的 `macos-14` runner 自带完整 Xcode + iOS SDK，是最省事的替代。
