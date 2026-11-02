import SwiftUI

@main
struct TagwerkApp: App {
    @State private var store: Store
    private let initialTab: AppTab
    private let openSettings: Bool

    init() {
        // Launch arguments become UserDefaults: -TWDemo YES -TWTab termine
        let defaults = UserDefaults.standard
        let tabArg = defaults.string(forKey: "TWTab") ?? ""
        _store = State(initialValue: Store(demo: defaults.bool(forKey: "TWDemo")))
        initialTab = AppTab(rawValue: tabArg) ?? (tabArg == "termine" ? .planer : .heute)
        openSettings = tabArg == "einstellungen"
    }

    var body: some Scene {
        WindowGroup {
            RootView(initialTab: initialTab, openSettings: openSettings)
                .environment(store)
                .environment(\.locale, germanLocale)
        }
    }
}
