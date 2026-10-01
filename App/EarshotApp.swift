import SwiftUI

@main
struct EarshotApp: App {

    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LiveView(model: model, reminder: model.reminder, activity: model.activity)
                .onAppear {
                    model.startListening()
                    model.reminder.schedule()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Background: iOS stops delivering unfiltered scan results, so hand the
                    // work to the node and keep only the filtered link alive. See
                    // docs/ios-limits.md for the Live Activity path that lifts this.
                    model.scanner.setForeground(phase == .active)
                }
        }
    }
}
