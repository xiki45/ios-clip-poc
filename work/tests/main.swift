import Foundation

var pass = 0, fail = 0
func check(_ cond: Bool, _ name: String, _ detail: String = "") {
    if cond { pass += 1; print("  ✓ \(name)") }
    else { fail += 1; print("  ✗ \(name) \(detail)") }
}
func eq(_ got: String, _ want: String, _ name: String) {
    check(got == want, name, "got=\(got.debugDescription) want=\(want.debugDescription)")
}

print("== Rewriter ==")
eq(Rewriter.apply("hello", steps: [RewriteStep(.base64Encode)]).output, "aGVsbG8=", "base64 encode")
eq(Rewriter.apply("aGVsbG8=", steps: [RewriteStep(.base64Decode)]).output, "hello", "base64 decode")
eq(Rewriter.apply("aGVsbG8", steps: [RewriteStep(.base64Decode)]).output, "hello", "base64 decode 无 padding")
eq(Rewriter.apply("???>", steps: [RewriteStep(.base64Encode, ["urlsafe": "true"])]).output, "Pz8_Pg==", "base64 urlsafe")
eq(Rewriter.apply("Pz8_Pg==", steps: [RewriteStep(.base64Decode)]).output, "???>", "base64 urlsafe decode")
eq(Rewriter.apply("a b&c", steps: [RewriteStep(.urlEncode)]).output, "a%20b%26c", "url encode")
eq(Rewriter.apply("a%20b%26c", steps: [RewriteStep(.urlDecode)]).output, "a b&c", "url decode")
eq(Rewriter.apply("hi", steps: [RewriteStep(.hexEncode)]).output, "6869", "hex encode")
eq(Rewriter.apply("6869", steps: [RewriteStep(.hexDecode)]).output, "hi", "hex decode")
check(Rewriter.apply("{\"b\":1,\"a\":2}", steps: [RewriteStep(.jsonPretty)]).output.contains("\"a\" : 2"), "json pretty")
eq(Rewriter.apply("  x  ", steps: [RewriteStep(.trim)]).output, "x", "trim")
eq(Rewriter.apply("b\na\nb", steps: [RewriteStep(.dedupeLines)]).output, "b\na", "dedupe lines")
eq(Rewriter.apply("b\na", steps: [RewriteStep(.sortLines)]).output, "a\nb", "sort lines")
eq(Rewriter.apply("a1b2", steps: [RewriteStep(.regexReplace, ["pattern": "\\d", "replacement": ""])]).output, "ab", "regex replace")
eq(Rewriter.apply("abc", steps: [RewriteStep(.upper)]).output, "ABC", "upper")
check(Rewriter.apply("x", steps: [RewriteStep(.sha256)]).output.count == 64, "sha256 长度")

let bad = Rewriter.apply("not-base64!!!", steps: [RewriteStep(.base64Decode)])
check(!bad.ok && bad.error != nil, "非法 base64 应失败")

let chain = Rewriter.apply("aGVsbG8=", steps: [RewriteStep(.base64Decode), RewriteStep(.upper)])
check(chain.ok && chain.output == "HELLO", "链式执行")
check(chain.steps.count == 2, "每步有结果")

print("== 自动识别 ==")
check(Rewriter.candidates(for: "aGVsbG8=").contains { $0.op == .base64Decode }, "识别 base64")
check(Rewriter.candidates(for: "{\"a\":1}").contains { $0.op == .jsonPretty }, "识别 json")
check(Rewriter.candidates(for: "a%20b").contains { $0.op == .urlDecode }, "识别 url 编码")
check(Rewriter.candidates(for: "随便一段话").isEmpty, "普通文本无候选")

print("== Tokenizer ==")
let t1 = Tokenizer.tokens("支付回调日志")
check(t1.contains("支付") && t1.contains("回调"), "中文 2-gram", "\(t1)")
let t2 = Tokenizer.tokens("getUserName 你好")
check(t2.contains("getusername"), "英文小写化", "\(t2)")
check(Tokenizer.matches("支付接口回调失败", query: "支付 回调"), "多 token AND")
check(!Tokenizer.matches("支付接口失败", query: "支付 回调"), "缺 token 不匹配")

print("== ClipStore ==")
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cliptest-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let store = ClipStore(directory: dir)

store.upsert("第一条", source: "app")
store.upsert("第二条", source: "keyboard")
store.upsert("第一条", source: "app")
check(store.visibleItems().count == 2, "重复内容去重", "\(store.visibleItems().count)")
check(store.visibleItems().first?.text == "第一条", "重复内容置顶")

let found = store.search("第一")
check(found.count == 1 && found.first?.text == "第一条", "搜索命中")

store.togglePin(id: store.visibleItems().last!.id)
check(store.visibleItems().first?.pinned == true, "置顶生效")

let target = store.visibleItems().first!.id
store.remove(id: target)
check(store.visibleItems().count == 1, "软删除生效")

Store2: do {
    let s2 = ClipStore(directory: dir)
    check(s2.visibleItems().count == 1, "重新加载持久化生效")
}

try? FileManager.default.removeItem(at: dir)

print("\n结果: pass=\(pass) fail=\(fail)")
exit(fail == 0 ? 0 : 1)
