//
//  Tokenizer.swift
//  剪贴板检索 + 分词（不是输入法用词库）
//
//  v11 改为「块感知」切分，边界按内容类型走，而不是一律按字符切：
//
//    文本 https://example.com/a?b=1 支付回调 getOrderId 2026-11-13
//    → 文本 / https://example.com/a?b=1 / 支付 回调 / get order id / 2026-11-13
//
//  - URL：整条保留（不拆成 http、com 之类碎片）
//  - 邮箱 / @提及：整条保留
//  - 英文：整词，驼峰再拆（getUserName → get user name），统一小写
//  - 数字 / 日期 / 版本号：连续 ASCII 段整条保留
//  - 中文：连续汉字按 2-gram **不重叠**切分，奇数尾字单独保留
//  - 其它标点：丢弃
//

import Foundation

public enum Tokenizer {

    // MARK: - 分词

    /// 人类可读分词：一段混排文本 → 词/字列表（顺序保持原文）
    public static func segments(_ text: String) -> [String] {
        let ch = Array(text)
        var out: [String] = []
        var i = 0

        while i < ch.count {
            let c = ch[i]

            // 1. URL（http/https/www/裸域名 + 路径）
            if let (token, len) = matchURL(ch, at: i) {
                out.append(token)
                i += len
                continue
            }

            // 2. ASCII 词：字母数字 + 内部 - _ . @ %（email / 版本号 / 日期 / 驼峰标识符）
            if isASCIIAlnum(c) {
                if let (token, len) = matchASCIIWord(ch, at: i) {
                    out.append(contentsOf: splitCamel(token))
                    i += len
                    continue
                }
            }

            // 3. 中文块：连续汉字，2-gram 不重叠
            if isCJK(c) {
                var j = i
                while j < ch.count, isCJK(ch[j]) { j += 1 }
                var k = i
                while k < j {
                    let end = min(k + 2, j)
                    out.append(String(ch[k..<end]))
                    k = end
                }
                i = j
                continue
            }

            i += 1
        }
        return out
    }

    /// 检索用分词（与 segments 同一套规则）
    public static func tokens(_ text: String) -> [String] {
        segments(text)
    }

    // MARK: - 匹配

    /// 搜索：所有 token 都要出现（AND，子串匹配）
    public static func matches(_ text: String, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let lower = text.lowercased()
        return tokens(q).allSatisfy { lower.contains($0) }
    }

    /// 高亮区间（用于搜索结果展示）
    public static func highlightRanges(in text: String, query: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        let lower = text.lowercased()
        for token in tokens(query) where !token.isEmpty {
            var searchStart = lower.startIndex
            while let r = lower.range(of: token, range: searchStart..<lower.endIndex) {
                ranges.append(r)
                searchStart = r.upperBound
                if ranges.count > 50 { break }
            }
        }
        return ranges
    }

    // MARK: - 字符判定

    public static func isCJK(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v)      // 基本汉字
            || (0x3400...0x4DBF).contains(v)      // 扩展 A
            || (0x3040...0x30FF).contains(v)      // 日文假名
            || (0xAC00...0xD7AF).contains(v)      // 韩文
    }

    private static func isASCIIAlnum(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    // MARK: - URL

    private static let urlStarters = ["https://", "http://", "ftp://", "www."]

    /// URL 允许的字符（RFC 3986 的常用子集）
    private static func isURLChar(_ c: Character) -> Bool {
        guard c.isASCII else { return false }
        if c.isLetter || c.isNumber { return true }
        return "-._~:/?#[]@!$&'()*+,;=%".contains(c)
    }

    /// URL 尾部不该保留的标点
    private static func isURLTrailingPunct(_ c: Character) -> Bool {
        ".,;:!?)]}'\"".contains(c)
    }

    private static func matchURL(_ ch: [Character], at i: Int) -> (String, Int)? {
        // ① 显式前缀
        var hasPrefix = false
        for p in urlStarters {
            let pc = Array(p)
            if i + pc.count <= ch.count, Array(ch[i..<(i + pc.count)]) == pc {
                hasPrefix = true
                break
            }
        }

        // ② 裸域名：host 至少含一个点，TLD 全是字母
        if !hasPrefix {
            guard isASCIIAlnum(ch[i]) else { return nil }
            var h = i
            while h < ch.count, isASCIIAlnum(ch[h]) || ch[h] == "." || ch[h] == "-" { h += 1 }
            let host = String(ch[i..<h])
            guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
            let tld = host.split(separator: ".").last.map(String.init) ?? ""
            guard tld.count >= 2, tld.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
            // 后面必须是 / 或空白或行尾，否则更像「v1.2」「1.2.3」这类
            if h < ch.count, !(ch[h] == "/" || ch[h].isWhitespace) { return nil }
        }

        var j = i
        while j < ch.count, isURLChar(ch[j]) { j += 1 }
        var end = j
        while end > i, isURLTrailingPunct(ch[end - 1]) { end -= 1 }
        guard end - i > 3 else { return nil }
        return (String(ch[i..<end]), end - i)
    }

    // MARK: - ASCII 词

    private static func matchASCIIWord(_ ch: [Character], at i: Int) -> (String, Int)? {
        guard i < ch.count, isASCIIAlnum(ch[i]) else { return nil }
        var j = i
        while j < ch.count {
            let c = ch[j]
            if isASCIIAlnum(c) {
                j += 1
            } else if "-_.@%".contains(c),
                      j + 1 < ch.count, isASCIIAlnum(ch[j + 1]) {
                // 内部连接符：必须后面还是字母数字，避免吃掉句末的点
                j += 1
            } else {
                break
            }
        }
        guard j > i else { return nil }
        return (String(ch[i..<j]), j - i)
    }

    /// getOrderId → get / order / id ；HTTPServer → http / server ；iPhone → i / phone
    private static func splitCamel(_ word: String) -> [String] {
        let chars = Array(word)
        var parts: [String] = []
        var start = 0
        var i = 1
        while i < chars.count {
            let prev = chars[i - 1], cur = chars[i]
            var boundary = false
            if cur.isUppercase {
                if prev.isLowercase || prev.isNumber {
                    boundary = true
                } else if prev.isUppercase, i + 1 < chars.count, chars[i + 1].isLowercase {
                    // 缩写后接新词：HTTPServer → HTTP | Server
                    boundary = true
                }
            }
            if boundary {
                parts.append(String(chars[start..<i]))
                start = i
            }
            i += 1
        }
        parts.append(String(chars[start..<chars.count]))
        return parts
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-_.@%")) }
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
    }
}
