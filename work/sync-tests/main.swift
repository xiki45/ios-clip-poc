import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ name: String, _ detail: String = "") {
    if c { pass += 1; print("  ✓ \(name)") } else { fail += 1; print("  ✗ \(name) \(detail)") }
}

func makeStore(_ tag: String) -> (ClipStore, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("synctest-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (ClipStore(directory: dir), dir)
}

func cfg(_ dev: String, _ id: String) -> SyncConfig {
    var c = SyncConfig()
    c.server = "http://127.0.0.1:18081/"
    c.username = "u"
    c.password = "p"
    c.deviceID = id
    c.deviceName = dev
    return c
}

let (storeA, _) = makeStore("a")
let (storeB, _) = makeStore("b")

print("== 设备 A 写入并推送 ==")
storeA.upsert("第一条：支付回调", source: "keyboard")
storeA.upsert("第二条：https://example.com/x", source: "keyboard")
storeA.upsert("第三条：base64 aGVsbG8=", source: "app")
check(storeA.items.count == 3, "A 本地 3 条")

let engA = try SyncEngine(config: cfg("iPad", "AAAA-1111"))
let s1 = try engA.sync(store: storeA)
print("  summary: \(s1.text)")
check(s1.generation >= 1, "A 推送后 generation ≥ 1", "\(s1.generation)")

print("== 设备 B 拉取 ==")
let engB = try SyncEngine(config: cfg("iPhone", "BBBB-2222"))
let s2 = try engB.sync(store: storeB)
print("  summary: \(s2.text)")
check(storeB.items.count == 3, "B 拉到 3 条", "\(storeB.items.count)")
check(storeB.items.contains { $0.text.contains("支付回调") }, "内容正确")

print("== 幂等：再同步一次 ==")
let s3 = try engB.sync(store: storeB)
print("  summary: \(s3.text)")
check(s3.unchanged, "第二次无变化")

print("== 增量：A 改一条，B 应拉到新版本 ==")
let target = storeA.items.first { $0.text.contains("支付回调") }!
storeA.update(id: target.id, text: "第一条：支付回调（已更新）")
let s4 = try engA.sync(store: storeA)
print("  A: \(s4.text)")
let s5 = try engB.sync(store: storeB)
print("  B: \(s5.text)")
check(storeB.items.contains { $0.text.contains("（已更新）") }, "B 拿到更新后的内容")

print("== 冲突：同一 id 两端各自改成 rev 相同但内容不同 ==")
let idc = storeB.items.first { $0.text.contains("已更新") }!.id
_ = storeA.update(id: idc, text: "A 侧改写 AAAAA")
_ = storeB.update(id: idc, text: "B 侧改写 BBBBB")
_ = try engA.sync(store: storeA)   // A 先推
let s6 = try engB.sync(store: storeB)  // B 遇到同 rev 不同 hash
print("  B: \(s6.text)")
check(s6.conflicts == 1, "检测到 1 个冲突", "\(s6.conflicts)")
check(storeB.items.contains { $0.id.contains("-conflict-") }, "生成了冲突副本")
check(storeB.items.count == 4, "B 变成 4 条（3 原有 + 1 副本）", "\(storeB.items.count)")

print("== 冲突后再同步：两端应看到同样的 4 条 ==")
_ = try engA.sync(store: storeA)
let s7 = try engB.sync(store: storeB)
print("  B: \(s7.text)")
let aLive = storeA.items.filter { !$0.deleted }.map { $0.id }.sorted()
let bLive = storeB.items.filter { !$0.deleted }.map { $0.id }.sorted()
check(aLive == bLive, "两端 id 集合一致", "A=\(aLive.count) B=\(bLive.count)")

print("\n结果: pass=\(pass) fail=\(fail)")
exit(fail == 0 ? 0 : 1)
