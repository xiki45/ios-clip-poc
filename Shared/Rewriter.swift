//
//  Rewriter.swift
//  剪贴板内容重写引擎（纯函数，无 IO、无网络）
//
//  与 Python 参考实现（tasks/clip-sync-prototype）保持语义一致，
//  可用 spec-conformance.json 的 41 条向量做回归。
//

import Foundation

// MARK: - 算子

public enum RewriteOp: String, Codable, CaseIterable {
    case base64Encode = "base64_encode"
    case base64Decode = "base64_decode"
    case urlEncode = "url_encode"
    case urlDecode = "url_decode"
    case hexEncode = "hex_encode"
    case hexDecode = "hex_decode"
    case jsonPretty = "json_pretty"
    case jsonMinify = "json_minify"
    case trim
    case upper
    case lower
    case sortLines = "sort_lines"
    case dedupeLines = "dedupe_lines"
    case numberLines = "number_lines"
    case regexReplace = "regex_replace"
    case sha256
    
    public var displayName: String {
        switch self {
        case .base64Encode: return "Base64 编码"
        case .base64Decode: return "Base64 解码"
        case .urlEncode: return "URL 编码"
        case .urlDecode: return "URL 解码"
        case .hexEncode: return "Hex 编码"
        case .hexDecode: return "Hex 解码"
        case .jsonPretty: return "美化 JSON"
        case .jsonMinify: return "压缩 JSON"
        case .trim: return "去首尾空白"
        case .upper: return "转大写"
        case .lower: return "转小写"
        case .sortLines: return "按行排序"
        case .dedupeLines: return "按行去重"
        case .numberLines: return "加行号"
        case .regexReplace: return "正则替换"
        case .sha256: return "SHA-256"
        }
    }
}

public struct RewriteStep: Codable, Equatable {
    public var op: RewriteOp
    public var params: [String: String]?

    public init(_ op: RewriteOp, _ params: [String: String]? = nil) {
        self.op = op
        self.params = params
    }
}

public struct RewriteStepResult {
    public let op: RewriteOp
    public let ok: Bool
    public let output: String
    public let error: String?
}

public struct RewriteResult {
    public let ok: Bool
    public let output: String
    public let steps: [RewriteStepResult]
    public let error: String?
}

// MARK: - 执行器

public enum Rewriter {

    public static func apply(_ input: String, steps: [RewriteStep]) -> RewriteResult {
        var current = input
        var stepResults: [RewriteStepResult] = []

        for step in steps {
            let r = run(current, step)
            stepResults.append(r)
            if r.ok {
                current = r.output
            } else {
                return RewriteResult(ok: false, output: current, steps: stepResults, error: r.error)
            }
        }
        return RewriteResult(ok: true, output: current, steps: stepResults, error: nil)
    }

    public static func run(_ input: String, _ step: RewriteStep) -> RewriteStepResult {
        do {
            let out = try perform(input, step)
            return RewriteStepResult(op: step.op, ok: true, output: out, error: nil)
        } catch let e as RewriteError {
            return RewriteStepResult(op: step.op, ok: false, output: input, error: e.message)
        } catch {
            return RewriteStepResult(op: step.op, ok: false, output: input, error: "未知错误")
        }
    }

    struct RewriteError: Error { let message: String }

    static func fail(_ msg: String) -> RewriteError { RewriteError(message: msg) }

    static func perform(_ input: String, _ step: RewriteStep) throws -> String {
        let p = step.params ?? [:]

        switch step.op {
        case .base64Encode:
            let data = Data(input.utf8)
            var s = data.base64EncodedString()
            if p["urlsafe"] == "true" {
                s = s.replacingOccurrences(of: "+", with: "-")
                     .replacingOccurrences(of: "/", with: "_")
                if p["strip_padding"] == "true" {
                    s = s.replacingOccurrences(of: "=", with: "")
                }
            }
            return s

        case .base64Decode:
            var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
            s = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
            while s.count % 4 != 0 { s += "=" }
            guard let data = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else {
                throw fail("不是有效的 Base64")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw fail("Base64 解码结果不是 UTF-8 文本")
            }
            return text

        case .urlEncode:
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return input.addingPercentEncoding(withAllowedCharacters: allowed) ?? input

        case .urlDecode:
            guard let s = input.removingPercentEncoding else { throw fail("不是有效的 URL 编码") }
            return s

        case .hexEncode:
            let upper = p["upper"] == "true"
            return input.utf8.map { String(format: upper ? "%02X" : "%02x", $0) }.joined()

        case .hexDecode:
            let clean = input.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "0x", with: "")
                .replacingOccurrences(of: "\n", with: "")
            guard clean.count % 2 == 0 else { throw fail("Hex 长度不是偶数") }
            var bytes: [UInt8] = []
            var idx = clean.startIndex
            while idx < clean.endIndex {
                let next = clean.index(idx, offsetBy: 2)
                guard let b = UInt8(clean[idx..<next], radix: 16) else { throw fail("包含非 Hex 字符") }
                bytes.append(b)
                idx = next
            }
            guard let s = String(bytes: bytes, encoding: .utf8) else { throw fail("解码结果不是 UTF-8") }
            return s

        case .jsonPretty:
            guard let obj = try? JSONSerialization.jsonObject(with: Data(input.utf8)) else {
                throw fail("不是合法 JSON")
            }
            let data = try JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            return String(data: data, encoding: .utf8) ?? input

        case .jsonMinify:
            guard let obj = try? JSONSerialization.jsonObject(with: Data(input.utf8)) else {
                throw fail("不是合法 JSON")
            }
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
            return String(data: data, encoding: .utf8) ?? input

        case .trim:
            return input.trimmingCharacters(in: .whitespacesAndNewlines)

        case .upper:
            return input.uppercased()

        case .lower:
            return input.lowercased()

        case .sortLines:
            let desc = p["desc"] == "true"
            let lines = input.components(separatedBy: "\n").sorted()
            return (desc ? lines.reversed() : lines).joined(separator: "\n")

        case .dedupeLines:
            var seen = Set<String>()
            var out: [String] = []
            for line in input.components(separatedBy: "\n") {
                if seen.insert(line).inserted { out.append(line) }
            }
            return out.joined(separator: "\n")

        case .numberLines:
            let start = Int(p["start"] ?? "1") ?? 1
            return input.components(separatedBy: "\n").enumerated()
                .map { "\($0.offset + start). \($0.element)" }
                .joined(separator: "\n")

        case .regexReplace:
            guard let pattern = p["pattern"], !pattern.isEmpty else { throw fail("缺少 pattern 参数") }
            let template = p["replacement"] ?? ""
            let options: NSRegularExpression.Options = p["flags"]?.contains("i") == true ? [.caseInsensitive] : []
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
                throw fail("正则不合法")
            }
            let range = NSRange(input.startIndex..., in: input)
            return re.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)

        case .sha256:
            return ClipItem.sha256(input)
        }
    }

    // MARK: - 自动识别（零思考层）

    /// 给出「这个内容可能想做什么」的候选，最多 3 个
    public static func candidates(for text: String) -> [RewriteStep] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        var out: [RewriteStep] = []

        // JSON
        if (t.hasPrefix("{") && t.hasSuffix("}")) || (t.hasPrefix("[") && t.hasSuffix("]")) {
            if (try? JSONSerialization.jsonObject(with: Data(t.utf8))) != nil {
                out.append(RewriteStep(.jsonPretty))
            }
        }

        // URL 编码
        if t.contains("%") && t.removingPercentEncoding != nil && t.removingPercentEncoding != t {
            out.append(RewriteStep(.urlDecode))
        }

        // Base64（长度 4 的倍数、字符集合法、解码后是 UTF-8）
        if t.count >= 8, t.count % 4 == 0,
           t.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=-_").inverted) == nil,
           let data = Data(base64Encoded: t.replacingOccurrences(of: "-", with: "+")
                                        .replacingOccurrences(of: "_", with: "/")),
           String(data: data, encoding: .utf8) != nil {
            out.append(RewriteStep(.base64Decode))
        }

        // URL
        if t.hasPrefix("http://") || t.hasPrefix("https://") {
            out.append(RewriteStep(.urlDecode))
        }

        // 多行
        if t.components(separatedBy: "\n").count >= 3 {
            out.append(RewriteStep(.dedupeLines))
        }

        // 去重
        var uniq: [RewriteStep] = []
        for s in out where !uniq.contains(where: { $0.op == s.op }) { uniq.append(s) }
        return Array(uniq.prefix(3))
    }
}
