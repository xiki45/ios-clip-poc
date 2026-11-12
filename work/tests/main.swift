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

print("== v10 新增算子 ==")
eq(Rewriter.apply("a   b\t\tc", steps: [RewriteStep(.collapseSpaces)]).output, "a b c", "合并空白")
eq(Rewriter.apply("a\n\n\nb\n", steps: [RewriteStep(.stripBlankLines)]).output, "a\nb", "去空行")
check(Rewriter.apply("支付回调日志", steps: [RewriteStep(.tokenize)]).output.contains("支付"), "分词算子")

print("== 可用算子过滤（v9 的关键 bug）==")
// 纯文本：v9 列出的 URL 解码/美化 JSON/按行去重全是 no-op 或必失败
let plain = "Syscon Infoway Pvt. Ltd"
let plainOps = Rewriter.options(for: plain).map { $0.op }
check(!plainOps.contains(.urlDecode), "纯文本不出现 URL 解码（no-op）")
check(!plainOps.contains(.jsonPretty), "纯文本不出现美化 JSON（必失败）")
check(!plainOps.contains(.dedupeLines), "单行不出现按行去重（no-op）")
check(plainOps.contains(.base64Encode), "纯文本保留 Base64 编码")
check(plainOps.contains(.upper), "纯文本保留转大写")
check(plainOps.contains(.sha256), "纯文本保留 SHA-256")
check(plainOps.count >= 5, "纯文本至少 5 个可用算子", "\(plainOps)")

let jsonOps = Rewriter.options(for: "{\"a\":1}").map { $0.op }
check(jsonOps.contains(.jsonPretty), "JSON 出现美化")
let multiOps = Rewriter.options(for: "b\na\nb").map { $0.op }
check(multiOps.contains(.dedupeLines) && multiOps.contains(.sortLines), "多行出现行算子")
let b64Ops = Rewriter.options(for: "aGVsbG8=").map { $0.op }
check(b64Ops.contains(.base64Decode), "Base64 串出现解码")
// 所有列出的算子都必须真的能改变内容
for text in [plain, "{\"a\":1}", "b\na\nb", "aGVsbG8=", "a%20b", "  空格  "] {
    let allEffective = Rewriter.options(for: text).allSatisfy { opt in
        let r = Rewriter.run(text, opt.step)
        return r.ok && r.output != text
    }
    check(allEffective, "列出的算子都有效果: \(text)", "\(Rewriter.options(for: text).map { $0.op })")
}

print("== Tokenizer ==")
let t1 = Tokenizer.tokens("支付回调日志")
check(t1 == ["支付", "回调", "日志"], "中文 2-gram 不重叠", "\(t1)")
let t2 = Tokenizer.tokens("getUserName 你好")
check(t2.contains("get") && t2.contains("user") && t2.contains("name"), "驼峰拆分", "\(t2)")
check(Tokenizer.matches("支付接口回调失败", query: "支付 回调"), "多 token AND")
check(!Tokenizer.matches("支付接口失败", query: "支付 回调"), "缺 token 不匹配")

print("== v11 分词：块感知 ==")
let seg = Tokenizer.tokens("文本 https://example.com/a?b=1 支付回调")
check(seg.contains("https://example.com/a?b=1"), "URL 作为整体一个 token", "\(seg)")
check(seg.contains("文本") && seg.contains("支付") && seg.contains("回调"), "URL 前后文本正常切", "\(seg)")
check(!seg.contains("http") && !seg.contains("com"), "URL 不再被拆碎", "\(seg)")

let seg2 = Tokenizer.tokens("联系 a@b.com 或 2026-11-13 或 Infoway 版本 v1.2")
check(seg2.contains("a@b.com"), "邮箱整体保留", "\(seg2)")
check(seg2.contains("2026-11-13"), "日期整体保留", "\(seg2)")
check(seg2.contains("infoway"), "英文单词整词小写", "\(seg2)")
check(!seg2.contains("https"), "无链接时不产生伪 URL", "\(seg2)")

let seg3 = Tokenizer.tokens("支付回调日")
check(seg3 == ["支付", "回调", "日"], "奇数长度尾字保留", "\(seg3)")

let seg4 = Tokenizer.tokens("见 https://infoway.com/x.")
check(seg4.contains("https://infoway.com/x"), "URL 尾部句点剥离", "\(seg4)")

let seg5 = Tokenizer.segments("https://www.zhihu.com/question/123?a=1#c")
check(seg5 == ["https://www.zhihu.com/question/123?a=1#c"], "带参数与锚点的完整 URL", "\(seg5)")

check(Tokenizer.matches("见 https://example.com/x", query: "example.com"), "域名可被搜索到")
check(Tokenizer.matches("getUserName 接口", query: "user"), "驼峰内单词可被搜索到")

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
