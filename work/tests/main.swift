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
eq(Rewriter.apply("abc", steps: [RewriteStep(.caseUpper)]).output, "ABC", "case_upper")
check(Rewriter.apply("x", steps: [RewriteStep(.sha256)]).output.count == 64, "sha256 长度")

let bad = Rewriter.apply("not-base64!!!", steps: [RewriteStep(.base64Decode)])
check(!bad.ok && bad.error != nil, "非法 base64 应失败")

let chain = Rewriter.apply("aGVsbG8=", steps: [RewriteStep(.base64Decode), RewriteStep(.caseUpper)])
check(chain.ok && chain.output == "HELLO", "链式执行")
check(chain.steps.count == 2, "每步有结果")

print("== 自动识别 ==")
check(Rewriter.candidates(for: "aGVsbG8=").contains { $0.op == .base64Decode }, "识别 base64")
check(Rewriter.candidates(for: "{\"a\":1}").contains { $0.op == .jsonPretty }, "识别 json")
check(Rewriter.candidates(for: "a%20b").contains { $0.op == .urlDecode }, "识别 url 编码")
check(Rewriter.candidates(for: "随便一段话").isEmpty, "普通文本无候选")

print("== v10/v12 算子 ==")
eq(Rewriter.apply("a   b\t\tc", steps: [RewriteStep(.collapseWhitespace)]).output, "a b c", "合并空白")
eq(Rewriter.apply("a\n\n\nb\n", steps: [RewriteStep(.stripBlankLines)]).output, "a\nb", "去空行")

print("== v12 对齐参考实现（22 op）==")
eq(Rewriter.apply("<a href=\"x\">'&'</a>", steps: [RewriteStep(.htmlEscape)]).output,
   "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;", "html escape")
eq(Rewriter.apply("&lt;b&gt; &amp; &#39;x&#39; &#x4E2D;", steps: [RewriteStep(.htmlUnescape)]).output,
   "<b> & 'x' 中", "html unescape（含数字实体）")
eq(Rewriter.apply("hello WORLD o'neil", steps: [RewriteStep(.caseTitle)]).output,
   "Hello World O'neil", "case_title")
eq(Rewriter.apply("id=42 name=x", steps: [RewriteStep(.regexExtract, ["pattern": "id=(\\d+)"])]).output,
   "42", "regex_extract 取第一组")
eq(Rewriter.apply("a1b2c3", steps: [RewriteStep(.regexExtract, ["pattern": "\\d", "flags": "g"])]).output,
   "1\n2\n3", "regex_extract g 模式")
check(Rewriter.apply("x", steps: [RewriteStep(.regexExtract, ["pattern": "zzz"])]).ok == false,
      "regex_extract 无匹配应失败")
eq(Rewriter.apply("abc", steps: [RewriteStep(.md5)]).output,
   "900150983cd24fb0d6963f7d28e17f72", "md5")
eq(Rewriter.apply("0", steps: [RewriteStep(.timestampToIso)]).output,
   "1970-01-01T00:00:00Z", "timestamp 秒")
eq(Rewriter.apply("1700000000000", steps: [RewriteStep(.timestampToIso)]).output,
   "2023-11-14T22:13:20Z", "timestamp 毫秒自动识别")
check(Rewriter.apply("notnum", steps: [RewriteStep(.timestampToIso)]).ok == false,
      "timestamp 非数字应失败")
// 参考实现的 22 个 op 必须一个不差（多出来的是 iOS 侧自有算子，不影响一致性）
let specOps: Set<String> = ["base64_encode","base64_decode","url_encode","url_decode",
    "hex_encode","hex_decode","json_pretty","json_minify","html_escape","html_unescape",
    "trim","collapse_whitespace","case_upper","case_lower","case_title","sort_lines",
    "dedupe_lines","regex_replace","regex_extract","md5","sha256","timestamp_to_iso"]
let mine = Set(RewriteOp.allCases.map { $0.rawValue })
let missing = specOps.subtracting(mine)
check(missing.isEmpty, "22 个标准算子齐全", "\(missing)")
check(RewriteOp.allCases.count == 24, "算子总数 24（22 标准 + 2 iOS 自有）", "\(RewriteOp.allCases.count)")

print("== 可用算子过滤（v9 的关键 bug）==")
// 纯文本：v9 列出的 URL 解码/美化 JSON/按行去重全是 no-op 或必失败
let plain = "Syscon Infoway Pvt. Ltd"
let plainOps = Rewriter.options(for: plain).map { $0.op }
check(!plainOps.contains(.urlDecode), "纯文本不出现 URL 解码（no-op）")
check(!plainOps.contains(.jsonPretty), "纯文本不出现美化 JSON（必失败）")
check(!plainOps.contains(.dedupeLines), "单行不出现按行去重（no-op）")
check(plainOps.contains(.base64Encode), "纯文本保留 Base64 编码")
check(plainOps.contains(.caseUpper), "纯文本保留转大写")
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

print("== TextMatch（分词已下线）==")
check(TextMatch.matches("支付接口回调失败", query: "支付 回调"), "多词 AND")
check(!TextMatch.matches("支付接口失败", query: "支付 回调"), "缺词不匹配")
check(TextMatch.matches("见 https://Example.com/x", query: "example.com"), "大小写不敏感")
check(TextMatch.matches("任意内容", query: "   "), "空查询放行")
check(TextMatch.isCJK("支") && !TextMatch.isCJK("a"), "CJK 判定")

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

print("== v15 图片 ==")
let imgData = Data(repeating: 0x89, count: 4096)
let img = store.upsertImage(imgData, source: "keyboard", pixel: "10×10")
check(img?.isImage == true, "图片条目 isImage")
check(img?.kind == "image", "kind 显示为 image")
check(store.attachmentData(for: img!) == imgData, "附件能读回原始字节")
let again = store.upsertImage(imgData, source: "keyboard")
check(again?.id == img?.id, "同一张图去重不新增")
check(store.visibleItems().count == 2, "图片进库后共 2 条", "\(store.visibleItems().count)")

print("== v15 撤销删除 ==")
let victim = store.visibleItems().first!
store.remove(id: victim.id)
check(!store.visibleItems().contains { $0.id == victim.id }, "删除后不可见")
store.restore(victim)
check(store.visibleItems().contains { $0.id == victim.id }, "撤销删除后回来了")
check(store.visibleItems().first?.id == victim.id, "撤销后仍按时间排在前面")

try? FileManager.default.removeItem(at: dir)

print("\n结果: pass=\(pass) fail=\(fail)")
exit(fail == 0 ? 0 : 1)
