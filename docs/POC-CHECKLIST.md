# POC 验证清单（打印/对照用）

> 设备：________________　iOS 版本：__________　安装方式：TrollStore / 自签 / 其他
> 日期：__________　构建：Release / Debug

---

## 0. 安装检查

| # | 检查项 | 结果 | 备注 |
|---|---|---|---|
| 0.1 | IPA 已安装，App 能打开 | ☐ | |
| 0.2 | 设置 → 键盘 → 键盘 里能看到 **ClipKeyboard** | ☐ | 看不到 = 扩展没嵌入 |
| 0.3 | ClipKeyboard 的「允许完全访问」已打开 | ☐ | POC 2 要对比开/关 |
| 0.4 | App 首页「嵌入的扩展」显示 `ClipKeyboard.appex` | ☐ | |
| 0.5 | `ldid -e` 或脚本回读的 entitlements 里有 `group.com.ouo.clipboardpoc` | ☐ | 关键，决定 POC1 |

---

## POC 1 · App Group 双向读写（最关键）

| # | 操作 | 期望 | 实际 | 结论 |
|---|---|---|---|---|
| 1.1 | App 首页看「结论」行 | ✅ 通过 / ❌ 容器为 nil | | |
| 1.2 | 看「group_container」路径 | 非 `nil`，形如 `/private/var/mobile/Containers/Shared/AppGroup/XXXX` | | |
| 1.3 | 点「App 写入 10 条」 | 日志出现 10 条 `app / group_write` | | |
| 1.4 | 任意输入框 → 切到 ClipKeyboard | 键盘显示 `group: 共享 ✅` | | |
| 1.5 | 键盘点「键盘写入」 | 键盘状态栏闪「已写入 5 条」 | | |
| 1.6 | 切回 App，下拉刷新 | 日志出现 `keyboard / group_write`（source 绿色） | | |
| 1.7 | 键盘再点「读剪贴板」后回 App | 能看到 `keyboard / pasteboard_kb` | | |

**判定**
- 1.6 通过 → **App Group 打通**，I-2 架构可行
- 1.6 失败但 1.3 成功、键盘显示「私有 ❌」→ 扩展的 entitlements 没生效（ldid 只签了 App）
- 1.1 显示容器 nil → 两者都没生效，见 README §5

> 记录：`group_container = ____________________________________`

---

## POC 2 · 键盘侧剪贴板能力

### 2A. 开启 Full Access

| # | 操作 | 期望 | 实际 |
|---|---|---|---|
| 2A.1 | 在 Safari 复制一段已知长度文本（如 20 字） | — | |
| 2A.2 | 切到 ClipKeyboard（自动 `on_appear` 探测） | 日志 `hasStrings=true len=20` | |
| 2A.3 | 点「读剪贴板」 | `len` 与真实长度一致，`cost` < 100ms 通常 | |
| 2A.4 | 点「插入文本」 | 输入框出现「来自 ClipKeyboard」 | |

### 2B. 关闭 Full Access 后重复（设置里关掉再试）

| # | 操作 | 期望 | 实际 |
|---|---|---|---|
| 2B.1 | 关闭「允许完全访问」 | — | |
| 2B.2 | 切到键盘，观察 `pasteboard_kb` | `len=nil` 或明显异常 → 记住这个差异 | |
| 2B.3 | 是否弹「允许粘贴」系统提示 | 记录：有 / 无，出现几次 | |

### 2C. 键盘生命周期

| # | 操作 | 期望 | 实际 |
|---|---|---|---|
| 2C.1 | 键盘可见时，App 里看「最后收到键盘心跳」 | 时间在 2s 内 | |
| 2C.2 | 关掉键盘，等 5 分钟 | 心跳时间**停在关闭时刻** | |
| 2C.3 | 再打开键盘 | pid 变化（进程被回收）或心跳恢复 | |
| 2C.4 | 记录 pid | 第一次：______　第二次：______ | |

**判定**
- 2A.2 正常 → 键盘可见期可采集，POC 2 通过
- 2A.2 `len=nil` → 需要注入方案（POC 4）或只能主 App 前台采集
- 2C.2 心跳停止 → 确认"键盘不常驻"，同步不能放扩展里

---

## POC 3 · 后台存活

| # | 操作 | 期望 | 实际 |
|---|---|---|---|
| 3.1 | App 点「开始后台心跳」 | 显示「已运行 0s」，剩余 ~30s | |
| 3.2 | 按 Home，锁屏 | — | |
| 3.3 | 等 10 分钟 | — | |
| 3.4 | 回 App 看日志 | `bg_heartbeat` 最大的 `elapsed` = 存活秒数 | |
| 3.5 | 重复一次，中途打开其他 App 再回来 | 记录是否被杀 | |

> **实测后台存活时长：________ 秒**（普通自签通常 ~30s）

**判定**
- < 60s → 后台采集不可行，靠键盘可见期 / 注入
- > 300s → 可做常驻轮询（配合 `platform-application` 等特权签名）

---

## 汇总：三项结论与架构选择

| POC | 结果 | 影响 |
|---|---|---|
| 1 App Group | ☐ 通过　☐ 失败 | 失败 → localhost 补丁 或 POC4 |
| 2 键盘读剪贴板 | ☐ 可读　☐ 不可读 | 不可读 → 采集移到主 App / POC4 |
| 3 后台存活 | ______ 秒 | >300s → 可常驻轮询 |

**决定走哪条**
- ☐ **I-2**：POC1 ✅ + POC2 可读 → 键盘可见时采集 + 主 App 同步（推荐起点）
- ☐ **I-2'**：POC1 ✅ + POC2 不可读 → 采集在主 App 前台，键盘只展示/插入
- ☐ **I-3**：POC4 注入可行 → 系统级自动采集

---

## 附：日志样例（把这段贴回来即可判断）

在 App 里滚动到日志区，截图或复制 10~20 行，形如：

```
app       app_launch 10:21:03
app       group_write 10:21:10
keyboard  kb_load 10:21:40 container=/private/var/mobile/Containers/Shared/AppGroup/...
keyboard  pasteboard_kb 10:21:41 reason=on_appear hasStrings=1 len=20 cost=3ms preview=...
keyboard  group_write 10:21:55
```
