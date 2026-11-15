//
//  PocApp.swift
//  PocApp
//
//  剪贴板库的宿主 App。自用/侧载场景，无 App Store 审核顾虑。
//

import SwiftUI

@main
struct PocApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    GroupStore.append(PocLogEntry(source: "app", event: "app_launch",
                                                  detail: "bundle=\(Bundle.main.bundleIdentifier ?? "?")"))
                }
        }
    }
}
