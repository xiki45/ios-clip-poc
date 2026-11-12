//
//  Rewriter.swift
//  剪贴板内容重写引擎（纯函数，无 IO、无网络）
//
//  与 Python 参考实现（tasks/clip-sync-prototype）保持语义一致，
//  可用 spec-conformance.json 的 41 条向量做回归。
//  v10 追加 collapseSpaces / stripBlankLines / tokenize 三个文本算子。
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
    // v10
    case collapseSpaces = "collapse_spaces"
    case stripBlankLines = "strip_blank_lines"
    case tokenize

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
        case .collapseSpaces: return "合并空白"
        case .stripBlankLines: return "去空行"
        case .tokenize: return "分词"
        }
    }

    /// 菜单里的分组，顺序即展示顺序
    public var section: String {
        switch self {
        case .base64Encode, .base64Decode, .urlEncode, .urlDecode,
             .hexEncode, .hexDecode, .jsonPretty, .jsonMinify:
            return "编码"
        case .trim, .upper, .lower, .sortLines, .dedupeLines,
             .numberLines, .collapseSpaces, .stripBlankLines, .tokenize, .regexReplace:
            return "文本"
        case .sha256:
            return "哈希"
        }
    }

    public var iconName: String {
        switch self {
        case .base64Encode, .base64Decode: return "chevron.left.forwardslash.chevron.right"
        case .urlEncode, .urlDecode: return "link"
        case .hexEncode, .hexDecode: return "number"
        case .jsonPretty, .jsonMinify: return "curlybraces"
        case .trim, .collapseSpaces, .stripBlankLines: return "scissors"
        case .upper, .lower: return "textformat.size"
        case .sortLines, .dedupeLines, .numberLines: return "list.number"
        case .regexReplace: return "asterisk"
        case .sha256: return "lock"
        case .tokenize: return "text.word.spacing"
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

    public var changed: Bool { ok && !steps.isEmpty && steps.last!.output != steps.first!.output }
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

        case .collapseSpaces:
            // 连续空白压成一个空格，换行保留（不破坏行结构）
            let lines = input.components(separatedBy: "\n").map { line -> String in
                var out = ""
                var lastWasSpace = false
                for ch in line {
                    if ch == " " || ch == "\t" || ch == "\u{3000}" {
                        if !lastWasSpace { out.append(" ") }
                        lastWasSpace = true
                    } else {
                        out.append(ch)
                        lastWasSpace = false
                    }
                }
                return out.trimmingCharacters(in: .whitespaces)
            }
            return lines.joined(separator: "\n")

        case .stripBlankLines:
            return input.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")

        case .tokenize:
            // 复用检索用分词器：中文 2-gram + 英文小写，空格连接，可直接当标签用
            return Tokenizer.tokens(input).joined(separator: " ")
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

        var uniq: [RewriteStep] = []
        for s in out where !uniq.contains(where: { $0.op == s.op }) { uniq.append(s) }
        return Array(uniq.prefix(3))
    }

    // MARK: - 可用算子（v10）

    /// 一个「点了确实会变」的选项
    public struct Option {
        public let step: RewriteStep
        public let title: String      // 显示名
        public let detail: String     // 结果预览

        public var op: RewriteOp { step.op }
    }

    /// 当前内容真正可用的算子：会失败的不列，点了不变的也不列。
    /// 这是 v10 的关键修正——v9 对纯文本列出三个 no-op，看起来像「功能没做」。
    public static func options(for text: String) -> [Option] {
        guard !text.isEmpty else { return [] }
        let lineCount = text.components(separatedBy: "\n").count
        let hasLetter = text.rangeOfCharacter(from: .letters) != nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        var out: [Option] = []

        for step in genericCandidates(reversed: false) {
            guard let changed = changedOutput(of: text, step: step) else { continue }
            out.append(Option(step: step, title: step.op.displayName, detail: preview(changed)))
        }

        // 解码类：只在能解、且结果不同时出现
        for step in decodeCandidates(for: text) {
            guard let changed = changedOutput(of: text, step: step) else { continue }
            out.append(Option(step: step, title: step.op.displayName, detail: preview(changed)))
        }

        // 行操作：单行无意义
        if lineCount >= 2 {
            for step in [RewriteStep(.dedupeLines), RewriteStep(.sortLines), RewriteStep(.numberLines),
                         RewriteStep(.stripBlankLines)] {
                guard let changed = changedOutput(of: text, step: step) else { continue }
                out.append(Option(step: step, title: step.op.displayName, detail: preview(changed)))
            }
        }

        // 文本类
        if trimmed != text, let s = changedOutput(of: text, step: RewriteStep(.trim)) {
            out.append(Option(step: RewriteStep(.trim), title: "去首尾空白", detail: preview(s)))
        }
        if hasLetter, let s = changedOutput(of: text, step: RewriteStep(.upper)) {
            out.append(Option(step: RewriteStep(.upper), title: "转大写", detail: preview(s)))
        }
        if hasLetter, let s = changedOutput(of: text, step: RewriteStep(.lower)) {
            out.append(Option(step: RewriteStep(.lower), title: "转小写", detail: preview(s)))
        }
        if let s = changedOutput(of: text, step: RewriteStep(.collapseSpaces)) {
            out.append(Option(step: RewriteStep(.collapseSpaces), title: "合并空白", detail: preview(s)))
        }
        if let s = changedOutput(of: text, step: RewriteStep(.tokenize)) {
            out.append(Option(step: RewriteStep(.tokenize), title: "分词", detail: preview(s)))
        }

        // 去重（按 op 收敛）
        var uniq: [Option] = []
        for o in out where !uniq.contains(where: { $0.op == o.op }) { uniq.append(o) }
        return uniq
    }

    /// 无条件可用的编码/哈希类（永远产生新内容）
    public static func genericCandidates(reversed: Bool) -> [RewriteStep] {
        let list: [RewriteStep] = [
            RewriteStep(.base64Encode),
            RewriteStep(.urlEncode),
            RewriteStep(.hexEncode),
            RewriteStep(.sha256),
            RewriteStep(.jsonPretty),
            RewriteStep(.jsonMinify)
        ]
        return reversed ? list.reversed() : list
    }

    /// 解码类
    public static func decodeCandidates(for text: String) -> [RewriteStep] {
        [
            RewriteStep(.base64Decode),
            RewriteStep(.urlDecode),
            RewriteStep(.hexDecode)
        ]
    }

    /// 执行一次；失败返回 nil；结果与输入相同返回 nil（no-op 不展示）
    private static func changedOutput(of text: String, step: RewriteStep) -> String? {
        let r = run(text, step)
        guard r.ok, r.output != text else { return nil }
        return r.output
    }

    public static func preview(_ s: String, limit: Int = 24) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ⏎ ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}
