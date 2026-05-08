import SwiftUI

@main
struct JottyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }   // suppresses the default window; menubar app
    }
}
