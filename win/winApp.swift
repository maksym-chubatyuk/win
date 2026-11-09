import SwiftUI
import UIKit

@main
struct winApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // The phone never sleeps while the app is in front: a program can run for a long
        // time with no touches (a benchmark, a cutscene, a game played with a controller).
        // iOS clears this whenever the app leaves the screen, so it is set again on return.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}

/// Supplies the orientations the app allows at the moment: any while in the menus,
/// landscape only while a Windows program is on screen (see OrientationLock).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

/// Programs get a landscape screen, the menus follow the phone.
@MainActor
enum OrientationLock {
    static private(set) var mask: UIInterfaceOrientationMask = .allButUpsideDown

    static func landscape(_ on: Bool) {
        let wanted: UIInterfaceOrientationMask = on ? .landscape : .allButUpsideDown
        guard wanted != mask else { return }
        mask = wanted
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: wanted))
        }
    }
}
