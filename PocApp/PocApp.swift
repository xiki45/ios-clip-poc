//
//  PocApp.swift
//  PocApp
//
//  POC 1/2/3 的宿主 App。自用/侧载场景，无 App Store 审核顾虑。
//

import SwiftUI

@main
struct PocApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    GroupStore.append(PocLogEntry(source: "app", event: "app_launch",
                                                  detail: "bundle=\(Bundle.main.bundleIdentifier ?? "?")"))
                }
        }
    }
}
