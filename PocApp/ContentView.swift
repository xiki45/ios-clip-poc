//
//  ContentView.swift
//  PocApp
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        verdictCard
                        diagnosisCard
                        poc1Card
                        keyboardCard
                        backgroundCard
                        clipboardCard
                        logCard
                    }
                    .padding(16)
                }
                if !model.toast.isEmpty {
                    Text(model.toast)
                        .font(.footnote)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
                        .padding(.bottom, 12)
                }
            }
            .navigationTitle("iOS 采集 POC")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("刷新") { model.refresh() }
                }
            }
        }
    }

    // MARK: - 卡片

    private var verdictCard: some View {
        section("结论", systemImage: "checkmark.seal") {
            Text(model.verdict)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("嵌入的扩展：\(model.embeddedExtension)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private var diagnosisCard: some View {
        section("诊断", systemImage: "stethoscope") {
            Text(model.report)
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var poc1Card: some View {
        section("POC 1 · App Group 双向读写", systemImage: "square.and.arrow.up.on.square") {
            Text("① 点「App 写入 10 条」→ ② 打开任意输入框切到 ClipKeyboard → ③ 点键盘上的「键盘写入」→ ④ 回来看下面的日志：两个 source 都出现即通过。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("App 写入 10 条") { model.writeFromApp() }
                    .buttonStyle(.borderedProminent)
                Button("清空日志") { model.clearLog() }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
            }
        }
    }

    private var keyboardCard: some View {
        section("POC 2 · 键盘侧状态", systemImage: "keyboard") {
            Text("最后收到键盘心跳：\(model.lastKeyboardSeen)")
                .font(.system(size: 12))
            Text(model.keyboardHeartbeat)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("键盘每 2s 写一次心跳；关掉键盘后心跳停止 = 扩展被挂起（这是正常行为）。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var backgroundCard: some View {
        section("POC 3 · 主 App 后台存活", systemImage: "clock.arrow.circlepath") {
            HStack {
                Text(model.backgroundRunning ? "已运行 \(model.backgroundElapsed)s" : "未运行")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("剩余 \(model.backgroundRemaining)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Button(model.backgroundRunning ? "停止后台心跳" : "开始后台心跳（锁屏放 30 分钟）") {
                model.toggleBackgroundHeartbeat()
            }
            .buttonStyle(.bordered)
            Text("普通签名通常 ~30s 后被杀；带 platform-application 等特权 entitlement 的自签包可能明显更久。日志里看 bg_heartbeat 的 elapsed 最大值。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var clipboardCard: some View {
        section("剪贴板对照组", systemImage: "doc.on.clipboard") {
            HStack(spacing: 12) {
                Button("写入测试文本") { model.copyTestText() }
                Button("App 读剪贴板") { model.readPasteboardFromApp() }
            }
            .buttonStyle(.bordered)
            Text("主 App 在前台时读剪贴板永远成功（对照组）。键盘侧读到什么，去日志里看 event=pasteboard_kb。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var logCard: some View {
        section("日志（最新在上，最多 200 条）", systemImage: "list.bullet.rectangle") {
            if model.entries.isEmpty {
                Text("暂无日志").foregroundColor(.secondary).font(.footnote)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.entries.prefix(60).enumerated()), id: \.offset) { _, e in
                        HStack(alignment: .top, spacing: 6) {
                            Text(e.source)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(color(for: e.source))
                                .frame(width: 52, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(e.event)  \(timeString(e.ts))")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                Text(e.detail)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 组件

    private func section<C: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .bold))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }

    private func color(for source: String) -> Color {
        switch source {
        case "app": return .blue
        case "keyboard": return .green
        case "dylib": return .purple
        default: return .gray
        }
    }

    private func timeString(_ ts: Double) -> String {
        AppModel.fmt.string(from: Date(timeIntervalSince1970: ts))
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView().environmentObject(AppModel())
    }
}
