//
//  SyncEngine.swift
//  WebDAV 同步（把 prototype/sync.py 的语义搬到 Swift）
//
//  远端布局（与 Python 参考实现一致）：
//      <root>/index.json          清单：items[] + generation + device_id + updated_at
//      <root>/blobs/<sha256>.txt  正文（内容寻址，天然去重）
//      <root>/devices/<id>.json   各设备水位
//
//  合并规则：
//      remote.rev > local.rev   → 采纳远端（取 blob）
//      remote.rev < local.rev   → 标记推送
//      rev 相等 & hash 相等     → 只对齐 pinned/deleted 元数据
//      rev 相等 & hash 不同     → 冲突：hash 字典序大的一方胜，rev = max+1，
//                                 输的一方另存一条 <id>-conflict-<hash8>
//
//  与 Python 版的差异：冲突副本的 id 用**内容 hash 前 8 位**而不是设备名 ——
//  这样两端各自算出来的 id 必然相同，不依赖设备名是否一致。
//

import Foundation

public struct SyncSummary {
    public var pulled = 0
    public var pushed = 0
    public var conflicts = 0
    public var generation = 0
    public var unchanged = false
    public var message: String = ""

    public var text: String {
        if unchanged && pulled == 0 && conflicts == 0 {
            return "已是最新（gen \(generation)）"
        }
        var parts: [String] = []
        if pulled > 0 { parts.append("拉取 \(pulled)") }
        if pushed > 0 { parts.append("推送 \(pushed)") }
        if conflicts > 0 { parts.append("冲突 \(conflicts)") }
        return "\(parts.joined(separator: " · "))（gen \(generation)）"
    }
}

public final class SyncEngine {

    private let client: WebDAVClient
    private let config: SyncConfig

    public init(config: SyncConfig) throws {
        let s = config.server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: s) else { throw DAVError.badURL(s) }
        if comps.scheme == nil { comps.scheme = "https" }
        guard let url = comps.url else { throw DAVError.badURL(s) }
        self.config = config
        self.client = WebDAVClient(base: url, username: config.username, password: config.password)
    }

    // MARK: - 入口

    public func sync(store: ClipStore, progress: (String) -> Void = { _ in }) throws -> SyncSummary {
        var summary = SyncSummary()

        progress("准备目录")
        _ = try client.ensureCollection("blobs")
        _ = try client.ensureCollection("devices")

        for attempt in 0..<3 {
            progress(attempt == 0 ? "拉取清单" : "重试 \(attempt)")
            let (status, index, etag) = try client.getJSON("index.json")
            guard status == 200 || status == 404 else {
                throw DAVError.status(status, "GET index.json")
            }
            let remoteRows = (index?["items"] as? [[String: Any]]) ?? []
            let remoteGen = (index?["generation"] as? Int) ?? 0

            progress("合并")
            var byID = Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0) })
            try merge(remote: remoteRows, into: &byID, summary: &summary)

            progress("写回本地")
            store.replaceAll(Array(byID.values))

            progress("比对差异")
            let localRows = store.items.map { indexRow($0) }
            let changed = hasChanges(local: localRows, remote: remoteRows)

            if !changed {
                summary.unchanged = true
                summary.generation = remoteGen
                summary.message = summary.text
                return summary
            }

            progress("推送正文")
            let remoteRevByID = Dictionary(uniqueKeysWithValues: remoteRows.compactMap { row -> (String, Int)? in
                guard let id = row["id"] as? String else { return nil }
                return (id, (row["rev"] as? Int) ?? 0)
            })
            for item in store.items {
                let rrev = remoteRevByID[item.id] ?? -1
                guard item.rev > rrev, !item.deleted else { continue }
                _ = try client.putText("blobs/\(item.hash).txt", item.text)
                summary.pushed += 1
            }

            progress("推送水位")
            _ = try client.putJSON("devices/\(config.deviceID).json", watermark(store: store))

            progress("推送清单")
            let gen = remoteGen + 1
            let payload: [String: Any] = [
                "items": localRows,
                "generation": gen,
                "device_id": config.deviceID,
                "updated_at": Self.iso(Date())
            ]
            let r = try client.putJSON("index.json", payload,
                                       ifMatch: etag, ifNoneMatch: etag == nil ? "*" : nil)
            if r.status == 412 {
                // 别人刚改过：丢掉本轮 summary 的推送计数，重来
                summary.pushed = 0
                continue
            }
            guard r.ok else { throw DAVError.status(r.status, "PUT index.json") }

            summary.generation = gen
            summary.message = summary.text
            return summary
        }
        throw DAVError.status(412, "清单反复被别人改动，稍后再试")
    }

    // MARK: - 合并

    private func merge(remote: [[String: Any]],
                       into byID: inout [String: ClipItem],
                       summary: inout SyncSummary) throws {
        for row in remote {
            guard let id = row["id"] as? String else { continue }
            let rrev = (row["rev"] as? Int) ?? 0
            let rhash = (row["hash"] as? String) ?? ""
            let rdel = (row["deleted"] as? Bool) ?? false
            let rpin = (row["pinned"] as? Bool) ?? false
            let rsrc = (row["source"] as? String) ?? "remote"
            let rdate = Self.parseDate(row["updated_at"] as? String) ?? Date()

            if var local = byID[id] {
                if rrev > local.rev {
                    if !rdel, let text = try client.getText("blobs/\(rhash).txt") {
                        local.text = text
                        local.hash = rhash
                    }
                    local.rev = rrev
                    local.deleted = rdel
                    local.pinned = rpin
                    local.updatedAt = rdate
                    byID[id] = local
                    summary.pulled += 1
                } else if rrev == local.rev {
                    if local.hash == rhash {
                        if local.deleted != rdel || local.pinned != rpin {
                            local.deleted = rdel
                            local.pinned = rpin
                            byID[id] = local
                        }
                    } else {
                        let newRev = max(local.rev, rrev) + 1
                        let localWins = local.hash > rhash
                        var winner = local
                        var loser = local
                        if !localWins {
                            if !rdel, let text = try client.getText("blobs/\(rhash).txt") {
                                winner.text = text
                                winner.hash = rhash
                            }
                            loser = local
                        }
                        winner.rev = newRev
                        loser.id = "\(id)-conflict-\(localWins ? String(rhash.prefix(8)) : String(local.hash.prefix(8)))"
                        loser.rev = newRev
                        byID[id] = winner
                        byID[loser.id] = loser
                        summary.conflicts += 1
                    }
                }
                // rrev < local.rev：本地更新，留给推送阶段
            } else {
                // 本地没有：整条收下
                var item = ClipItem(text: "", source: rsrc)
                item.id = id
                item.rev = rrev
                item.deleted = rdel
                item.pinned = rpin
                item.updatedAt = rdate
                if !rdel, let text = try client.getText("blobs/\(rhash).txt") {
                    item.text = text
                    item.hash = rhash
                } else {
                    item.hash = rhash
                }
                byID[id] = item
                summary.pulled += 1
            }
        }
    }

    // MARK: - 序列化

    private func indexRow(_ item: ClipItem) -> [String: Any] {
        [
            "id": item.id,
            "hash": item.hash,
            "rev": item.rev,
            "deleted": item.deleted,
            "pinned": item.pinned,
            "source": item.source,
            "updated_at": Self.iso(item.updatedAt)
        ]
    }

    private func watermark(store: ClipStore) -> [String: Any] {
        let perID = Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0.rev) })
        return [
            "device_id": config.deviceID,
            "name": config.deviceName,
            "max_rev": store.items.map { $0.rev }.max() ?? 0,
            "per_id": perID,
            "updated_at": Self.iso(Date())
        ]
    }

    private func hasChanges(local: [[String: Any]], remote: [[String: Any]]) -> Bool {
        let remoteMap = Dictionary(uniqueKeysWithValues: remote.compactMap { row -> (String, [String: Any])? in
            guard let id = row["id"] as? String else { return nil }
            return (id, row)
        })
        if local.count != remote.count { return true }
        for row in local {
            guard let id = row["id"] as? String else { continue }
            guard let r = remoteMap[id] else { return true }
            let lrev = (row["rev"] as? Int) ?? 0
            let rrev = (r["rev"] as? Int) ?? 0
            if lrev != rrev { return true }
            if (row["hash"] as? String) != (r["hash"] as? String) { return true }
            if (row["deleted"] as? Bool) != (r["deleted"] as? Bool) { return true }
            if (row["pinned"] as? Bool) != (r["pinned"] as? Bool) { return true }
        }
        return false
    }

    // MARK: - 时间

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
