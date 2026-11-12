# iOS 采集 POC（App Group / 键盘剪贴板 / 后台存活）

> 目的：在你的巨魔设备上，用 **半小时** 验证三件事，再决定 iOS 侧走 I-2（键盘可见时采集）还是 I-3（SpringBoard 注入）。
>
> - **POC 1**：自签的 App 与键盘扩展，能不能共用同一个 App Group 容器？
> - **POC 2**：键盘扩展在**没有 Full Access / 有 Full Access** 时，读系统剪贴板分别是什么结果？键盘关闭后还会不会活？
> - **POC 3**：自签 App 在后台能活多久？
>
> 三项结论直接决定架构，不需要先写 4000 行。

---

## 0. 已构建好的产物（CI 产出，可直接装）

`PocApp.ipa` —— 用 `codesign --force --sign - --entitlements` 签名，entitlements 为标准 blob，
CI 里会用 `codesign -d --entitlements` 回读并断言 `group.com.ouo.clipboardpoc` 存在，缺失即构建失败。

产物已确认包含 `PlugIns/ClipKeyboard.appex`。

构建记录：<https://github.com/xiki45/ios-clip-poc/actions>

### 0.1 键盘怎么用（v10）

| 操作 | 效果 |
|---|---|
| 切到 ClipKeyboard | 自动采集当前剪贴板，之后每 1.5s 轮询 `changeCount` |
| 点条目 | 直接插入到光标处 |
| **点条目右侧 ✨** | 弹出重写菜单（推荐 / 编码 / 文本 / 哈希） |
| 长按条目 | 同样的重写菜单 + 置顶 + 删除 |
| 搜索栏 | 分词检索（中文 2-gram + 英文小写，多关键词 AND） |

重写菜单只列**当前内容真的会变**的算子：v9 把「URL 解码 / 美化 JSON / 按行去重」固定列出，对纯文本要么原样返回、要么直接报错，看起来像功能没做。v10 改成按内容过滤——纯文本会出现 Base64 编码 / URL 编码 / Hex 编码 / SHA-256 / 转大写 / 转小写 / 分词等，每项后面直接跟着结果预览。

---

## 1. 工程结构

```
output/
├── PocApp.xcodeproj/          # 两个 target：PocApp（宿主）+ ClipKeyboard（键盘扩展）
├── PocApp/
│   ├── PocApp.swift           # @main
│   ├── AppModel.swift         # 状态与三个 POC 的操作
│   ├── ContentView.swift      # 验证面板 UI
│   ├── Info.plist
│   └── PocApp.entitlements    # com.apple.security.application-groups
├── ClipKeyboard/
│   ├── KeyboardViewController.swift   # POC2 全部逻辑
│   ├── Info.plist             # RequestsOpenAccess = YES
│   └── ClipKeyboard.entitlements
├── Shared/                    # 两个 target 共同编译
│   ├── GroupStore.swift       # App Group 读写 + JSONL 日志 + 心跳
│   └── Diagnostics.swift      # 用 SecTask* 探测 entitlement 是否生效
├── build-ipa.sh               # 构建 + 写 entitlements + 打 IPA
├── docs/POC-CHECKLIST.md      # 逐条验证清单（照着勾）
└── poc4-dylib/                # 可选：TrollFools 注入用的 dylib 模板
```

**关键标识（要改就一起改）**

| 项 | 值 |
|---|---|
| App Bundle ID | `com.ouo.clipboardpoc` |
| 扩展 Bundle ID | `com.ouo.clipboardpoc.keyboard`（必须以 App ID 为前缀） |
| App Group | `group.com.ouo.clipboardpoc`（代码 `GroupStore.groupID`、两个 entitlements 三处一致） |

---

## 2. 构建

### 2.1 前置

- macOS + **Xcode**（含 iOS SDK；只有 Command Line Tools 不行）
- `xcode-select -p` 应指向 `/Applications/Xcode.app/Contents/Developer`
- 可选：`ldid`（推荐，TrollStore 能正确保留 entitlements）  
  `brew install ldid` 或从 https://github.com/ProcursusTeam/ldid 编译

### 2.2 一条命令出 IPA

```bash
cd output
chmod +x build-ipa.sh
./build-ipa.sh Release
# 产物：./PocApp.ipa
# entitlements 回读：./build/check-app-entitlements.plist / check-ext-entitlements.plist
```

脚本做的事：
1. `xcodebuild -target PocApp -sdk iphoneos CODE_SIGNING_ALLOWED=NO`（先拿到未签名 .app）
2. 用 `ldid -S` 把两份 entitlements **分别**写进 `PocApp` 和 `ClipKeyboard` 两个二进制
3. 回读 entitlements 供你核对
4. 打成 `Payload/PocApp.app` → `PocApp.ipa`

> ⚠️ 本仓库在只有 Command Line Tools 的机器上无法编译验证。若首次编译报错，优先看第 5 节。

### 2.3 用 Xcode 打开（可选，便于改代码）

双击 `PocApp.xcodeproj`。默认构建配置已关闭自动签名（`CODE_SIGNING_ALLOWED = NO`），所以 **Run 到真机会失败**，这是预期的——真机安装走 2.2 的脚本 + TrollStore。

---

## 3. 安装与准备

1. TrollStore 打开 `PocApp.ipa` → 安装
2. 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → **ClipKeyboard**
3. 点进 ClipKeyboard，打开 **允许完全访问**（POC 要对比开/关两种情况，先开）
4. 打开 `采集POC` App

---

## 4. 三个验证（详细步骤见 `docs/POC-CHECKLIST.md`）

### POC 1 · App Group

| 步骤 | 期望 |
|---|---|
| App 首页看「结论」 | `✅ POC1 通过` 或 `❌ 容器为 nil` |
| 点「App 写入 10 条」 | 日志出现 `app / group_write` |
| 切到任意输入框 → ClipKeyboard → 点「键盘写入」 | 键盘日志出现，**回到 App 能看到 source=keyboard 的记录** |
| 回 App 看日志 | 出现 `keyboard / group_write` 即打通 |

**判定**
- 两端都能看到彼此记录 → **通过**，I-2 架构成立
- App 显示 `group_container: nil` → entitlement 没生效：检查 `ldid -S` 是否对**两个二进制都**用了正确的 entitlements 文件
- 扩展显示「私有 ❌」而 App 显示共享 → 只给 App 签了 entitlements，扩展漏了

### POC 2 · 键盘侧剪贴板

| 步骤 | 观察点 |
|---|---|
| 在 Safari 复制一段文字 | — |
| 切到 ClipKeyboard（触发 `on_appear` 自动探测） | 日志 `pasteboard_kb hasStrings=true len=N` |
| 点「读剪贴板」 | `len` 是否等于真实长度；`cost` 是否异常大（弹窗会拖到几百 ms） |
| 关掉键盘 5 分钟后再打开 | 主 App 里「最后收到键盘心跳」应停在 5 分钟前 → **证明键盘不常驻** |
| 点「插入文本」 | 输入框出现「来自 ClipKeyboard」 |

**判定**
- `len=N` 正常 → 键盘可读剪贴板，采集可在键盘可见时做
- `hasStrings=true` 但 `len=nil` → 读不到内容（无 Full Access 或被拦），需要靠 POC4 补
- 关键盘后心跳停止但重启后 `pid` 变化 → 扩展被回收，符合预期

### POC 3 · 后台存活

| 步骤 | 期望 |
|---|---|
| App 点「开始后台心跳」 | 状态变「已运行 0s」，剩余时间约 30s |
| 按 Home 键 / 锁屏，等 10 分钟 | — |
| 回 App | 日志里 `bg_heartbeat` 的 `elapsed` 最大值 = 实际存活秒数 |

**判定**
- 只有 ~30s → 普通自签，后台采集不可行，必须靠键盘可见期或注入
- 明显更长（几百秒以上）→ 特权 entitlement 生效，可考虑常驻轮询

---

## 5. 常见失败与排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `xcodebuild: error: SDK "iphoneos" cannot be located` | 只有 Command Line Tools | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| 编译报 `No such module 'UIKit'` | 同上 / 未装 iOS 平台 | Xcode → Settings → Platforms → 下载 iOS |
| 设置里看不到 ClipKeyboard | 扩展未嵌入，或 bundle id 不是 App id 的前缀 | 检查 `PocApp.app/PlugIns/ClipKeyboard.appex` 是否存在；TrollStore 里用「刷新应用注册」或 `uicache -a` |
| 扩展能被 Xcode 构建但真机不加载 | principal class 解析失败 | plist 用 `$(PRODUCT_MODULE_NAME).KeyboardViewController` 时，类**不要**加 `@objc(...)` 重命名 |
| 键盘闪退 | principal class 名不对 | plist 里是 `$(PRODUCT_MODULE_NAME).KeyboardViewController`，类上有 `@objc(KeyboardViewController)` |
| App Group 一直 nil | entitlements 没写进二进制 | `ldid -e PocApp.app/PocApp` 看有没有 `com.apple.security.application-groups` |
| 装了新版本数据还在但容器变了 | TrollStore 重装会换容器路径 | 属正常，POC 只验证“能否共享”，不验证持久化 |

**降级方案（POC 1 不通时）**：主 App 起一个 `127.0.0.1` 本地 HTTP 服务，扩展通过 localhost 拉数据——fcitx5-ios 在无 App Group 时就是这么做的。能用，但扩展必须有 Full Access 才允许 localhost 网络。

---

## 6. 验证完之后

| POC 结果组合 | 建议架构 |
|---|---|
| 1 ✅ + 2 可读 | **I-2**：键盘可见时采集 + 主 App 同步，最干净 |
| 1 ✅ + 2 不可读 | 采集靠主 App 前台 + 键盘只负责展示/插入；或上 POC4 |
| 1 ❌ | 走 localhost 补丁，或上 POC4（注入后不依赖 App Group 也能落库） |
| 3 存活 > 5 分钟 | 可加常驻轮询，采集延迟从“开键盘才记”降到分钟级 |

POC4（TrollFools 注入 SpringBoard）见 `poc4-dylib/README.md`，属于增强项，建议 POC1~3 跑完再决定要不要做。

---

## 7. 代码里几个刻意的设计

- **日志用 JSONL 追加写**：两个进程并发写同一文件不会互相覆盖（`O_APPEND` 语义），便于判断“到底谁写了”。
- **`GroupStore.effectiveDirectory`**：拿不到 App Group 时静默退化到私有沙盒，UI 上明确显示「私有 ❌」——避免“以为通了其实各写各的”。
- **`Diagnostics` 用 dlsym 动态取 `SecTask*`**：符号缺失时降级而不是崩，且验证完可以整段删除。
- **心跳与日志分离**：心跳是覆盖写（小），日志是追加写（大），避免定时器把日志刷爆。
