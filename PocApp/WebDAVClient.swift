//
//  WebDAVClient.swift
//  极简 WebDAV 客户端：只要 GET / PUT / MKCOL / DELETE / PROPFIND + Basic Auth + ETag
//
//  和 Python 参考实现（prototype/dav_client.py）行为对齐：
//  普通 HTTP 方法，不引第三方库；同步请求靠信号量包装，调用方必须在后台线程。
//

import Foundation

public struct DAVResponse {
    public let status: Int
    public let data: Data
    public let etag: String?

    public var ok: Bool { (200...299).contains(status) }
}

public enum DAVError: LocalizedError {
    case badURL(String)
    case network(String)
    case status(Int, String)

    public var errorDescription: String? {
        switch self {
        case .badURL(let s): return "地址不合法：\(s)"
        case .network(let s): return "网络错误：\(s)"
        case .status(let code, let msg): return "HTTP \(code) \(msg)"
        }
    }
}

public final class WebDAVClient {

    private let base: URL
    private let authHeader: String?
    private let session: URLSession

    public init(base: URL, username: String, password: String) {
        self.base = base
        if username.isEmpty {
            self.authHeader = nil
        } else {
            let raw = "\(username):\(password)"
            self.authHeader = "Basic " + Data(raw.utf8).base64EncodedString()
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.httpAdditionalHeaders = ["User-Agent": "ClipKeyboard/1.0"]
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - 请求

    /// path 是相对 root 的路径，如 "index.json" / "blobs/abc.txt"；空串表示 root 本身
    public func request(_ method: String,
                        _ path: String,
                        body: Data? = nil,
                        headers: [String: String] = [:]) throws -> DAVResponse {
        var url = base
        if !path.isEmpty {
            for comp in path.split(separator: "/") {
                url.appendPathComponent(String(comp))
            }
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw DAVError.badURL(url.absoluteString)
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        if let a = authHeader { req.setValue(a, forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if body != nil { req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }

        var result: DAVResponse?
        var failure: Error?
        let sem = DispatchSemaphore(value: 0)

        session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err { failure = DAVError.network(err.localizedDescription); return }
            guard let http = resp as? HTTPURLResponse else {
                failure = DAVError.network("没有 HTTP 响应")
                return
            }
            let etag = http.value(forHTTPHeaderField: "ETag")
            result = DAVResponse(status: http.statusCode, data: data ?? Data(), etag: etag)
        }.resume()

        if sem.wait(timeout: .now() + 70) == .timedOut {
            throw DAVError.network("超时")
        }
        if let f = failure { throw f }
        guard let r = result else { throw DAVError.network("空响应") }
        return r
    }

    // MARK: - 便捷方法

    @discardableResult
    public func ensureCollection(_ path: String) throws -> Bool {
        let r = try request("MKCOL", path)
        // 201 新建 / 405 已存在 / 301 已存在（部分服务端）
        return r.status == 201 || r.status == 405 || r.status == 301
    }

    public func getJSON(_ path: String) throws -> (Int, [String: Any]?, String?) {
        let r = try request("GET", path)
        if r.status == 404 { return (404, nil, nil) }
        guard r.ok else { return (r.status, nil, r.etag) }
        let obj = (try? JSONSerialization.jsonObject(with: r.data)) as? [String: Any]
        return (r.status, obj, r.etag)
    }

    public func putJSON(_ path: String,
                        _ obj: [String: Any],
                        ifMatch: String? = nil,
                        ifNoneMatch: String? = nil) throws -> DAVResponse {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        var h: [String: String] = ["Content-Type": "application/json"]
        if let m = ifMatch { h["If-Match"] = m }
        if let n = ifNoneMatch { h["If-None-Match"] = n }
        return try request("PUT", path, body: data, headers: h)
    }

    public func putText(_ path: String, _ text: String) throws -> DAVResponse {
        try request("PUT", path, body: Data(text.utf8))
    }

    public func putData(_ path: String, _ data: Data) throws -> DAVResponse {
        try request("PUT", path, body: data)
    }

    public func getData(_ path: String) throws -> Data? {
        let r = try request("GET", path)
        guard r.ok else { return nil }
        return r.data
    }

    public func getText(_ path: String) throws -> String? {
        let r = try request("GET", path)
        guard r.ok else { return nil }
        return String(data: r.data, encoding: .utf8)
    }
}
