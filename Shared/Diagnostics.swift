//
//  Diagnostics.swift
//  Shared
//
//  目的：在设备上直接回答“我的签名到底带没带 App Group entitlement”。
//  实现用 dlsym 动态查找 Security 的 SecTask* 私有符号 —— 找不到就降级，
//  不会因为符号缺失而链接失败或崩溃。
//
//  说明：SecTask* 是私有 API，App Store 上架会踩审核；本 POC 是自用/侧载场景，
//  且在 POC 验证完成后可以整体删掉，不影响正式代码。
//

import Foundation
import Security
import Darwin

public enum Diagnostics {

    private typealias SecTaskCreateFromSelfFn =
        @convention(c) (CFAllocator?) -> CFTypeRef?
    private typealias SecTaskCopyValueFn =
        @convention(c) (CFTypeRef?, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> CFTypeRef?

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let h = dlopen(nil, RTLD_LAZY), let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    /// 读取本进程的 entitlements 字典；私有 API 不可用时返回空字典并给出原因。
    public static func entitlements() -> (values: [String: Any], note: String) {
        guard let create = symbol("SecTaskCreateFromSelf", as: SecTaskCreateFromSelfFn.self),
              let copy   = symbol("SecTaskCopyValueForEntitlement", as: SecTaskCopyValueFn.self) else {
            return ([:], "SecTask 符号不可用（降级：仅依据容器路径判断）")
        }
        guard let task = create(nil) else {
            return ([:], "SecTaskCreateFromSelf 返回 nil")
        }
        var err: Unmanaged<CFError>?
        guard let any = copy(task, "com.apple.security.application-groups" as CFString, &err) else {
            return ([:], "未声明 com.apple.security.application-groups")
        }
        let groups = (any as? [String]) ?? []
        return (["com.apple.security.application-groups": groups], "OK")
    }

    /// entitlement 里是否包含我们的 group id
    public static func declaredGroups() -> [String] {
        let e = entitlements().values["com.apple.security.application-groups"] as? [String]
        return e ?? []
    }

    /// 一句话结论，直接显示在 UI 上
    public static func verdict(source: String) -> String {
        let groups = declaredGroups()
        let hasEntitlement = groups.contains(GroupStore.groupID)
        let hasContainer = GroupStore.containerURL != nil
        let shared = GroupStore.effectiveDirectory?.isShared ?? false

        switch (hasEntitlement, hasContainer, shared) {
        case (true, true, true):
            return "✅ POC1 通过：entitlement 已声明，App Group 容器可用（\(source)）"
        case (false, true, true):
            return "⚠️ 容器可用但 entitlement 探测失败（私有 API 受限），以容器读写结果为准"
        case (_, false, _):
            return "❌ 容器为 nil：签名未带 App Group entitlement（检查 ldid/codesign 是否用了 entitlements）"
        default:
            return "❌ 已退化到私有沙盒：两端无法共享数据"
        }
    }

    /// 供 UI 展示的完整诊断文本
    public static func report(source: String) -> String {
        let snap = GroupStore.snapshot(source: source)
        let ent = entitlements()
        var lines: [String] = []
        lines.append("── 结论 ──")
        lines.append(verdict(source: source))
        lines.append("")
        lines.append("── 运行时 ──")
        for k in snap.keys.sorted() { lines.append("\(k): \(snap[k] ?? "")") }
        lines.append("")
        lines.append("── entitlements ──")
        lines.append("探测: \(ent.note)")
        lines.append("groups: \(declaredGroups().isEmpty ? "(空)" : declaredGroups().joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }
}
