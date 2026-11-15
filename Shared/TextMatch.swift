//
//  TextMatch.swift
//  检索用的极简匹配（替代原来的 Tokenizer）
//
//  决定（2026-11-16）：分词不做，交给主键盘。
//  这里只保留三件小事：按空白切词、大小写不敏感的多词 AND、判断是否 CJK。
//  比原来的 FMM 分词器小两个数量级，键盘扩展内存预算紧张时这点很重要。
//

import Foundation

public enum TextMatch {

    /// 按空白切词并小写化；空串返回空数组
    public static func tokens(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
    }

    /// 多词 AND：每个词都要在文本里出现（大小写不敏感）
    public static func matches(_ text: String, query: String) -> Bool {
        let ts = tokens(query)
        guard !ts.isEmpty else { return true }
        let lower = text.lowercased()
        return ts.allSatisfy { lower.contains($0) }
    }

    public static func isCJK(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v)      // 基本汉字
            || (0x3400...0x4DBF).contains(v)      // 扩展 A
            || (0x3040...0x30FF).contains(v)      // 日文假名
            || (0xAC00...0xD7AF).contains(v)      // 韩文
    }
}
