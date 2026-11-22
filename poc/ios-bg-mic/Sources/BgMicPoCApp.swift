import SwiftUI

@main
struct BgMicPoCApp: App {
    @StateObject private var logger: EventLogger
    @StateObject private var monitor: AudioMonitor

    init() {
        let logger = EventLogger()
        _logger = StateObject(wrappedValue: logger)
        _monitor = StateObject(wrappedValue: AudioMonitor(logger: logger))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(monitor)
                .environmentObject(logger)
        }
    }
}
