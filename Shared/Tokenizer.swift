//
//  Tokenizer.swift
//  检索用分词（不是输入法用词库）
//
//  中文：连续汉字按 2-gram 切分（"支付回调" → 支付/付回/回调），
//        外加整段匹配，兼顾召回与零词典成本。
//  英文/数字：按非字母数字切分并小写。
//

import Foundation

public enum Tokenizer {

    public static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var latin = ""
        var cjk = ""

        func flushLatin() {
            if !latin.isEmpty {
                out.append(latin.lowercased())
                latin = ""
            }
        }
        func flushCJK() {
            if !cjk.isEmpty {
                let chars = Array(cjk)
                if chars.count == 1 {
                    out.append(cjk)
                } else {
                    for i in 0..<(chars.count - 1) {
                        out.append(String(chars[i...(i + 1)]))
                    }
                }
                cjk = ""
            }
        }

        for ch in text {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-") {
                flushCJK()
                latin.append(ch)
            } else if isCJK(ch) {
                flushLatin()
                cjk.append(ch)
            } else {
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()
        return out
    }

    public static func isCJK(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v)      // 基本汉字
            || (0x3400...0x4DBF).contains(v)      // 扩展 A
            || (0x3040...0x30FF).contains(v)      // 日文假名
            || (0xAC00...0xD7AF).contains(v)      // 韩文
    }

    /// 搜索匹配：所有 token 都要出现（AND）
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
}
