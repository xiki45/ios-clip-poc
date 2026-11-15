# ClipKeyboard 核心代码地图

> 仓库：<https://github.com/xiki45/ios-clip-poc>（`main`）
> 本地：`2026-11-05T19:18-mobile-ime-research/tasks/ios-poc-appgroup/output/`
> 现状：v15 · 55 个提交 · Swift 3042 行（不含注释约 2100 行）

---

## 1. 三层结构

```
Shared/        两个 target 共同编译 —— 真正的核心
ClipKeyboard/  键盘扩展（采集 + 面板 + 插入）
PocApp/        宿主 App（管理界面 + 同步）
```

| 目录 | 文件 | 行数 | 职责 | 核心？ |
|---|---|---|---|---|
| Shared | `ClipModel.swift` | 336 | `ClipItem` 数据模型 + `ClipStore` 本地库 | ★★★ |
| Shared | `Rewriter.swift` | 568 | 22 个重写算子 + 自动识别候选 | ★★★ |
| Shared | `TextMatch.swift` | 36 | 检索匹配（多词 AND） | ★★ |
| Shared | `GroupStore.swift` | 147 | App Group 容器定位 + JSONL 日志 + 心跳 | ★★ |
| ClipKeyboard | `KeyboardViewController.swift` | 247 | 采集循环 / 插入 / 重写 / 轮询 | ★★★ |
| ClipKeyboard | `ClipPanelView.swift` | 440 | 面板 UI（chip、列表、重写菜单） | ★★★ |
| PocApp | `AppModel.swift` | 236 | 库状态 + 同步动作 | ★★★ |
| PocApp | `ContentView.swift` | 458 | 列表 / 编辑 / 设置 | ★★ |
| PocApp | `SyncEngine.swift` | 266 | 合并 / 冲突 / 推送 | ★★★ |
| PocApp | `WebDAVClient.swift` | 138 | GET/PUT/MKCOL + Basic Auth + ETag | ★★ |
| PocApp | `SyncConfig.swift` | 58 | 同步配置存取 | ★ |

**记忆锚点**：核心只有两个文件——`ClipModel.swift`（数据怎么存）和 `KeyboardViewController.swift`（数据怎么来）。
其余都是围绕它们的「读法」和「写法」。

---

## 2. 采集链路（最核心的 30 行）

```
用户复制 → 切到 ClipKeyboard
    ↓ viewDidAppear
startPolling()            Timer 1.5s，仅在键盘可见时跑
    ↓ 每 1.5s
capture()
    ├─ pb.changeCount != lastChangeCount ?   ← 变了才继续
    ├─ pb.hasImages → pb.image → pngData()
    │     └─ store.upsertImage(data, pixel: "W×H")   ← 按内容 hash 去重
    ├─ pb.string
    └─ store.upsert(text, source: "keyboard")
            ├─ hash 命中已有 & 未删除 → updatedAt/rev++，挪到最前（去重）
            └─ 否则 ClipItem(text:) 插到 index 0 → trim(500) → save()
    ↓
panel.reload()
```

关键约束：

- **只能轮询，不能监听**：`UIPasteboard` 没有变更通知，扩展也没有后台执行权。
- **只在键盘可见时采**：`viewWillDisappear` 里 `pollTimer.invalidate()`。
- **必须开「允许完全访问」**，否则 `pb.string` 返回 nil。

---

## 3. 数据模型

`ClipItem`（`ClipModel.swift`）

| 字段 | 类型 | 作用 |
|---|---|---|
| `id` | String (UUID) | 同步主键 |
| `text` | String | 正文 |
| `hash` | String | `SHA256(text)` 大写十六进制，去重 + 内容寻址 |
| `createdAt` / `updatedAt` | Date | 排序 |
| `pinned` | Bool | 置顶，同步时也传 |
| `source` | String | `app` / `keyboard` / `rewrite` / `remote` / `pc` |
| `rev` | Int | **单调递增**，同步的唯一比较依据 |
| `deleted` | Bool | 软删（tombstone），同步要传，否则别处会「复活」 |
| `type` | String? | `nil`/`"text"` 文本，`"image"` 图片（老数据无此字段，解码补 nil） |
| `attachment` | String? | 附件文件名，落在 `<容器>/attachments/<hash>.png` |
| `pixelSize` | String? | `"800×600"`，只用于展示 |

落盘：`<App Group>/clip-items.json`，全量 JSON 数组，`prettyPrinted + sortedKeys`。
500 条上限（`ClipStore.maxItems`），超出按 `updatedAt` 裁，**置顶的永不裁**。

---

## 4. 同步链路（v14）

```
设置页「立即同步」
  → LibraryModel.runSync()            （后台线程，别卡 UI）
      → SyncEngine(config).sync(store:)
           1. MKCOL blobs / devices
           2. GET index.json  (+ ETag)
           3. merge  ← 见下
           4. store.replaceAll(merged)
           5. PUT blobs/<hash>.txt   仅本地 rev 更高的
           6. PUT devices/<self>.json
           7. PUT index.json  If-Match: ETag → 412 就重来（≤3 次）
```

合并判定表：

| 远端 vs 本地 | 动作 |
|---|---|
| `rev` 更大 | 采纳远端（按 hash 取 blob） |
| `rev` 更小 | 留着，交给推送 |
| `rev` 相等、`hash` 相等 | 只对齐 `pinned`/`deleted` |
| `rev` 相等、`hash` 不同 | 冲突：hash 字典序大者胜，`rev = max+1`，败者存 `<id>-conflict-<hash8>` |

约定：**「当前剪贴板」不是模型的一部分**。这里存的是历史库，SyncClipboard 那种
单条 `SyncClipboard.json` 的格式不支持，也不打算支持（两套模型不兼容）。

---

## 5. 关键不变量（改代码前先看这几条）

1. `rev` 只增不减；任何写操作都要 `rev += 1`，否则同步会漏。
2. 删除必须留 tombstone（`deleted = true`），物理删会让别的设备把它「复活」。
3. `hash` 必须和 `text` 同步更新（`update(id:text:)` 里重算），否则同步把内容对错。
4. `upsert` 是幂等的：同内容只更新时间戳，不产生新条目。
5. 键盘扩展内存上限约 77MB：**不要在键盘里读整份 JSON 之外的任何大文件**。
6. `TextMatch` 只做子串匹配，分词交给主键盘（2026-11-16 决定）。

---

## 6. 要加功能该改哪

| 想加的东西 | 改这里 |
|---|---|
| ~~图片~~ | ✅ v15 已做：`ClipItem.type/attachment/pixelSize`、`upsertImage`、二进制 blob |
| 敏感内容过滤（密码类） | `capture()` 里加判定，命中就 `return` 不入库 |
| 记录来源 App | `capture()` 里取 `pb` 无此信息，需主 App 侧 `UIPasteboard.detectedPatterns` 或注入；扩展拿不到 |
| 自动同步 | `AppModel` 的定时器 + `scenePhase`；iOS 后台限制大，别指望后台定时 |
| 快捷短语 | `Shared` 加 `Snippet` 模型 + 键盘里监听 `textDidChange` 匹配触发词（本次跳过） |
| 面板换风格 | 只改 `ClipPanelView.swift`，不碰其它 |

---

## 7. 已知脆弱点

| 位置 | 问题 | 影响 |
|---|---|---|
| `KeyboardViewController.capture` | 1.5s 轮询，连续复制两次只留最后一次 | 会丢中间态（系统剪贴板本身也只留最后一次，接受） |
| `ClipStore.save` | 全量重写 JSON | 500 条时约 1MB，键盘里同步写会卡 10–20ms（可接受，别再加字段） |
| `SyncEngine` | 没做孤儿 blob 清理（PROPFIND） | 删掉的条目正文仍留在服务器 |
| 键盘插入图片 | `insertText` 只能插文本 | 图片只能「复制到剪贴板」再长按粘贴 |
| 附件目录 | 只增不删 | 删条目后 `attachments/` 里的图还在，需要定期清 |

---

## 8. 构建

没有本地 Xcode 的机器上也能出包（本机就是这种情况）：

```bash
# GitHub Actions：推送 main 自动构建
.github/workflows/build-ipa.yml → PocApp.ipa

# 本机只跑纯逻辑测试（不需要 iOS SDK）
swiftc -swift-version 5 -O Shared/Rewriter.swift Shared/ClipModel.swift \
    Shared/TextMatch.swift work/tests/main.swift -o /tmp/cliptest && /tmp/cliptest
# → pass=64 fail=0

# 同步回归（起 MiniWebDAV + 两台虚拟设备）
work/sync-tests/run.sh
# → pass=10 fail=0
```
