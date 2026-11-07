# POC 4 · TrollFools 注入验证（可选）

> 目标：验证注入到 **SpringBoard** 后能否观测系统剪贴板写入。
> 成立 → 采集不必等键盘出现，可做系统级自动记录；不成立 → 老实走 I-2（键盘可见时采集）。

## 1. 编译

```bash
cd poc4-dylib
chmod +x build.sh
./build.sh
# 产出 poc4.dylib
```

## 2. 注入

1. 用 **TrollFools** 选中 `SpringBoard`（或先拿一个普通 App 试水，比如「设置」）
2. 添加 `poc4.dylib`
3. 重启该进程（TrollFools 会提示；SpringBoard 重启 = 桌面闪一下）

> 第一次建议先注入一个**普通 App**（如「备忘录」）验证 hook 生效，再上 SpringBoard，降低把桌面搞崩的成本。

## 3. 观察

**方式 A：Console.app / 设备日志**
```
过滤进程：SpringBoard
关键字：[POC4]
```

**方式 B：文件**
```
/var/mobile/Library/Preferences/poc-pasteboard.log
```
（用 Filza 或 `cat` 查看；路径不可写时以日志为准）

## 4. 验证步骤

| # | 操作 | 期望 |
|---|---|---|
| 4.1 | 重启 SpringBoard 后看日志 | `dylib loaded` + 两条 `hooked` |
| 4.2 | 在 Safari 选中文字 → 拷贝 | `setString len=...` |
| 4.3 | 从相册复制图片 | `setItems count=1` |
| 4.4 | 用另一台设备隔空投送/通用剪贴板复制 | 是否也有事件（可能走不同 API，留意漏采） |

## 5. 判定与后续

| 结果 | 结论 |
|---|---|
| 4.2 有事件 | ✅ 可做系统级采集；下一步把 POC 的 `GroupStore` 逻辑搬进 dylib（注意 SpringBoard 没有你的 App Group entitlement，改用固定路径 + 主 App 读） |
| 4.2 无事件 | ⚠️ 该版本 `UIPasteboard` 写入路径不在 `setString:`/`setItems:`（可能走 XPC / `setData:forPasteboardType:`）；可再加 hook 点，或放弃注入路线 |
| SpringBoard 崩溃 | 立刻在 TrollFools 里移除 dylib；用「先注入普通 App」的方式定位问题 |

## 6. 已知限制

- SpringBoard 与你的 App 不是同一沙盒，**不能直接共享 App Group**；落盘用固定路径，主 App 用 `NSFileManager` 读（自签特权包通常可读 `/var/mobile/Library/Preferences/`）。
- 只 hook 了 `setString:` 与 `setItems:`，漏采风险存在（见 4.4）。
- 系统升级后 hook 点可能变化。
- 这条路线只用于自用验证，不上架。
