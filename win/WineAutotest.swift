import Foundation
import UIKit

/// Development check, on only when scripts/jit-run.sh sets WIN_AUTOTEST. It drives the
/// same input path as typing, posts taps into Wine's input queue, and saves what the app
/// is showing as Documents/screen-*.png, so a run can be checked from the Mac.
enum WineAutotest {
    private static let environment = ProcessInfo.processInfo.environment
    static let isEnabled = environment["WIN_AUTOTEST"] == "1"

    private static var doneFile: URL { URL.documentsDirectory.appending(path: "autotest-done.txt") }
    private static var notes = [String]()

    static func prepare() {
        guard isEnabled else { return }
        try? FileManager.default.removeItem(at: doneFile)
        let screens = (try? FileManager.default.contentsOfDirectory(atPath: URL.documentsDirectory.path(percentEncoded: false))) ?? []
        for file in screens where file.hasPrefix("screen-") {
            try? FileManager.default.removeItem(at: URL.documentsDirectory.appending(path: file))
        }
        for name in [String]() {
            try? FileManager.default.removeItem(at: URL.documentsDirectory.appending(path: "screen-\(name).png"))
        }
        if environment["WIN_CLEAN_TESTS"] == "1" { removeTestPrograms() }
        if environment["WIN_CLEAN_SLATE"] == "1" { cleanSlate() }
    }

    /// WIN_CLEAN_SLATE=1: removes what development runs left in the app: the benchmark
    /// and test program folders, shader dumps, logs, screenshots and the settings tests
    /// changed. Folders the user imported are kept and listed.
    private static func cleanSlate() {
        let manager = FileManager.default
        let testFolders: Set<String> = ["Superposition", "bench-arm64", "bench-x64"]
        var removed = [String](), kept = [String]()
        let programs = (try? manager.contentsOfDirectory(at: ProgramLibrary.root, includingPropertiesForKeys: nil)) ?? []
        for folder in programs {
            let name = folder.lastPathComponent
            if testFolders.contains(name) || name.hasPrefix("Test App") || name.hasPrefix("win-") || name.hasPrefix(".import-") {
                if (try? manager.removeItem(at: folder)) != nil { removed.append(name) }
            } else {
                kept.append(name)
            }
        }
        // DXMT_SHADER_DUMP folders in C:\, and the run logs in Documents.
        let driveC = ProgramLibrary.root.deletingLastPathComponent()
        for item in (try? manager.contentsOfDirectory(at: driveC, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.hasPrefix("shaders") || item.lastPathComponent.hasPrefix("sh-") {
            if (try? manager.removeItem(at: item)) != nil { removed.append("C:\\" + item.lastPathComponent) }
        }
        let documents = URL.documentsDirectory
        for file in (try? manager.contentsOfDirectory(atPath: documents.path(percentEncoded: false))) ?? []
        where file.hasPrefix("madeira-log") || file.hasPrefix("autotest-") || file.hasPrefix("screen-")
            || ["wine-stderr.txt", "wine-output.txt"].contains(file) {
            if (try? manager.removeItem(at: documents.appending(path: file))) != nil { removed.append(file) }
        }
        UserDefaults.standard.removeObject(forKey: "touchControllerVisible")
        UserDefaults.standard.removeObject(forKey: ScreenResolution.storageKey)
        notes.append("clean slate: removed \(removed.joined(separator: ", "))")
        notes.append("clean slate: kept programs \(kept.joined(separator: ", "))")
    }

    private static func removeTestPrograms() {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: ProgramLibrary.root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.lastPathComponent.hasPrefix("Test App") || folder.lastPathComponent.hasPrefix("win-") {
            try? manager.removeItem(at: folder)
        }
    }

    /// Runs the real import code on a bundled test program, then returns the imported copy
    /// named by WIN_LIBRARY_EXE. WIN_IMPORT_TEST picks the source: "1" for a folder whose
    /// name has a space in it, "file" for the .exe alone. The system file picker is the one
    /// step this skips, because it cannot be driven from inside the app.
    static func preparedProgram() async -> WindowsProgram? {
        guard let wanted = environment["WIN_LIBRARY_EXE"] else { return nil }
        if let mode = environment["WIN_IMPORT_TEST"] {
            do {
                try await Task.detached { try importBundledCopy(of: wanted, asFolder: mode == "1") }.value
                notes.append("import: ok")
            } catch {
                notes.append("import: \(error.localizedDescription)")
            }
        }
        // The list has to be on screen long enough to appear in the screenshot.
        try? await Task.sleep(for: .seconds(2))
        snapshot("0-library")

        let programs = await Task.detached { ProgramLibrary.programs() }.value
        notes.append("library: " + programs.map { "\($0.windowsPath) [\($0.architecture.label)\($0.isConsole ? ", console" : "")]" }
            .joined(separator: "; "))
        return programs.first { $0.fileName == wanted }
    }

    private nonisolated static func importBundledCopy(of name: String, asFolder: Bool) throws {
        let manager = FileManager.default
        let bundle = Bundle.main.bundleURL
        let candidates = ["arm64ec-windows", "aarch64-windows"].map { bundle.appending(path: "\($0)/\(name)") }
        guard let source = candidates.first(where: { manager.fileExists(atPath: $0.path(percentEncoded: false)) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard asFolder else {
            try ProgramLibrary.importItem(from: source)
            return
        }
        let holding = manager.temporaryDirectory.appending(path: "Test App \(UUID().uuidString.prefix(4))")
        try manager.createDirectory(at: holding, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: holding) }
        try manager.copyItem(at: source, to: holding.appending(path: name))
        try ProgramLibrary.importItem(from: holding)
    }

    /// Starts the built-in JIT helper with a request that needs no pairing file, to check
    /// that the app finds the extension, starts it and gets an answer back.
    static func testHelperRoundTrip() async {
        guard environment["WIN_TEST_HELPER"] == "1" else { return }
        let response = await BuiltInJIT.resetDiskImage()
        notes.append("helper: success=\(response.success) message=\(response.message)")
        notes.append("helper: pairing file present=\(BuiltInJIT.hasPairingFile) loopback reachable=\(BuiltInJIT.isLoopbackReachable())")
    }

    /// WIN_PAD_TEST=1: drives the on-screen controller's state through a fixed sequence
    /// (A, left stick right, right trigger, D-pad up plus B, release), 2 seconds each,
    /// for tests/guest/win-xinput.c to print what XInput reports.
    @MainActor
    static func padSequence() async {
        if environment["WIN_PAD_TEST"] == "touch" { await padTouchSequence(); return }
        guard environment["WIN_PAD_TEST"] == "1" else { return }
        let bridge = GamepadBridge.shared
        bridge.touchVisible = true
        let steps: [PadState] = [
            PadState(buttons: .a),
            PadState(leftX: 1),
            PadState(rightTrigger: 1),
            PadState(buttons: [.up, .b]),
            PadState(),
        ]
        for step in steps {
            try? await Task.sleep(for: .seconds(2))
            bridge.touch = step
        }
        notes.append("pad sequence sent")
    }

    /// WIN_PAD_PRESSES: "seconds:button,..." presses on the on-screen controller, each held
    /// for a quarter second at that many seconds after the program starts, then a screenshot
    /// named press-1, press-2, ... Buttons: a b x y lb rb start back up down left right.
    @MainActor
    static func padPresses() async {
        guard let plan = environment["WIN_PAD_PRESSES"] else { return }
        let names: [String: PadButtons] = [
            "a": .a, "b": .b, "x": .x, "y": .y, "lb": .leftShoulder, "rb": .rightShoulder,
            "start": .menu, "back": .view, "up": .up, "down": .down, "left": .left, "right": .right,
        ]
        let bridge = GamepadBridge.shared
        bridge.touchVisible = true
        var elapsed = 0.0
        for (index, item) in plan.split(separator: ",").enumerated() {
            let parts = item.split(separator: ":")
            guard parts.count == 2, let at = Double(parts[0]), let button = names[String(parts[1])] else {
                notes.append("pad press \(item): not understood"); continue
            }
            if at > elapsed { try? await Task.sleep(for: .seconds(at - elapsed)); elapsed = at }
            bridge.touch = PadState(buttons: button)
            try? await Task.sleep(for: .milliseconds(250))
            bridge.touch = PadState()
            try? await Task.sleep(for: .milliseconds(1500))
            elapsed += 1.75
            snapshot("press-\(index + 1)")
        }
        notes.append("pad presses sent")
    }

    /// WIN_PAD_TEST=touch (with WIN_SHOW_PAD=1): simulated fingers through the on-screen
    /// controller's own touch code, 2 seconds apart: left half dragged right, then right
    /// half dragged up as well, both released, RB and LT held, then A.
    @MainActor
    static func padTouchSequence() async {
        // A console program never shows the window by itself, so the test opens it.
        if ControlsWindow.controllerView == nil {
            ControlsWindow.show(true, controllerMode: true, onMode: { _ in }, onKeyboard: {})
        }
        GamepadBridge.shared.touchVisible = true
        try? await Task.sleep(for: .milliseconds(500))
        guard let view = ControlsWindow.controllerView else { notes.append("pad touch: no controller"); return }
        try? await Task.sleep(for: .seconds(2))
        view.simulate(finger: "left", phase: .began, x: 0.2, y: 0.7)
        view.simulate(finger: "left", phase: .moved, x: 0.3, y: 0.7)
        try? await Task.sleep(for: .seconds(2))
        view.simulate(finger: "right", phase: .began, x: 0.6, y: 0.5)
        view.simulate(finger: "right", phase: .moved, x: 0.6, y: 0.3)
        try? await Task.sleep(for: .milliseconds(300))
        snapshot("pad-sticks")
        try? await Task.sleep(for: .seconds(2))
        view.simulate(finger: "left", phase: .ended, x: 0.3, y: 0.7)
        view.simulate(finger: "right", phase: .ended, x: 0.6, y: 0.3)
        try? await Task.sleep(for: .seconds(2))
        for (finger, label) in [("rb", "RB"), ("lt", "LT")] {
            guard let at = view.fraction(ofButton: label) else { notes.append("pad touch: no \(label)"); continue }
            view.simulate(finger: finger, phase: .began, x: at.x, y: at.y)
        }
        try? await Task.sleep(for: .seconds(2))
        for finger in ["rb", "lt"] { view.simulate(finger: finger, phase: .ended, x: 0, y: 0) }
        if let at = view.fraction(ofButton: "A") {
            view.simulate(finger: "a", phase: .began, x: at.x, y: at.y)
            try? await Task.sleep(for: .seconds(2))
            view.simulate(finger: "a", phase: .ended, x: at.x, y: at.y)
        }
        notes.append("pad touch sequence sent")
    }

    static func run(isConsole: Bool, surface: WineSurface) async {
        Task { await padSequence() }
        Task { await padPresses() }
        let deadline = Date().addingTimeInterval(120)
        if isConsole {
            var exitCode: Int32 = 0
            while !win_wine_finished(&exitCode) && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(500))
            }
            notes.append(win_wine_finished(&exitCode)
                         ? "console program exit code: \(exitCode)"
                         : "console program still running after 120 s")
            try? await Task.sleep(for: .seconds(1))
            snapshot("1-started")
            finish()
            return
        }

        while winios_surface_present_count() == 0 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
        }
        let frames = winios_surface_present_count()
        notes.append("window frames presented: \(frames)")

        try? await Task.sleep(for: .seconds(frames == 0 ? 0 : 6))
        snapshot("1-started")

        // Each step is held open so its result can be seen in the next screenshot.
        // WIN_NO_TYPING keeps the sample text out of programs that are not Notepad.
        if environment["WIN_NO_TYPING"] != "1" {
            surface.insertText("Hello from iOS\nTyped into Notepad")
        }
        try? await Task.sleep(for: .seconds(environment["WIN_NO_TYPING"] == "1" ? 20 : 2))
        snapshot("2-typed")

        // WIN_TAPS: "x,y,seconds;x,y,seconds;..." taps in Windows screen pixels, each
        // followed by a wait and a screenshot named tap-1, tap-2, ...
        if let script = environment["WIN_TAPS"] {
            for (index, step) in script.split(separator: ";").enumerated() {
                let parts = step.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 3 else { continue }
                await press(x: Int32(parts[0]), y: Int32(parts[1]))
                try? await Task.sleep(for: .seconds(parts[2]))
                snapshot("tap-\(index + 1)")
            }
        }

        if let tap = environment["WIN_TAP"] {
            let parts = tap.split(separator: ",").compactMap { Int32($0) }
            if parts.count == 2 {
                await press(x: parts[0], y: parts[1])
                snapshot("3-tapped")

                // A second press, because the first can be used up by window activation.
                await press(x: parts[0], y: parts[1])
                snapshot("4-tapped-again")
            }
        }

        // WIN_ENGINE_CONSOLE: commands typed into a game engine's console (opened and closed
        // with the ` key), separated by ";;", each followed by Return.
        if let script = environment["WIN_ENGINE_CONSOLE"] {
            surface.pressKeyForTest(0xC0)
            try? await Task.sleep(for: .seconds(1))
            for command in script.components(separatedBy: ";;") {
                surface.insertText(command)
                try? await Task.sleep(for: .milliseconds(500))
                surface.insertText("\n")
                try? await Task.sleep(for: .seconds(1))
            }
            snapshot("console")
            surface.pressKeyForTest(0xC0)
        }

        // WIN_SNAPSHOT_EVERY: "seconds,count" more screenshots while the program runs,
        // named run-1, run-2, ...
        if let plan = environment["WIN_SNAPSHOT_EVERY"]?.split(separator: ",").compactMap({ Int($0) }), plan.count == 2 {
            for index in 1...max(plan[1], 1) {
                try? await Task.sleep(for: .seconds(plan[0]))
                snapshot("run-\(index)")
                notes.append("run-\(index): Direct3D frames so far \(madeira_frame_count())")
                try? notes.joined(separator: "\n").write(to: doneFile.deletingLastPathComponent().appending(path: "autotest-progress.txt"), atomically: true, encoding: .utf8)
            }
        }

        notes.append("frames at end: \(winios_surface_present_count())")
        finish()
    }

    private static func press(x: Int32, y: Int32) async {
        winios_post_touch_down(x, y)
        try? await Task.sleep(for: .milliseconds(100))
        winios_post_touch_up(x, y)
        try? await Task.sleep(for: .seconds(2))
    }

    private static func finish() {
        try? notes.joined(separator: "\n").write(to: doneFile, atomically: true, encoding: .utf8)
    }

    private static func snapshot(_ name: String) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        // Every window, lowest first, so ControlsWindow shows over the program.
        let windows = (scene?.windows ?? []).filter { !$0.isHidden }.sorted { $0.windowLevel < $1.windowLevel }
        guard let bottom = windows.first else {
            notes.append("\(name): no window")
            return
        }
        let renderer = UIGraphicsImageRenderer(bounds: bottom.bounds)
        let data = renderer.pngData { _ in
            for window in windows {
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }
        do {
            try data.write(to: URL.documentsDirectory.appending(path: "screen-\(name).png"))
            notes.append("\(name): saved \(data.count) bytes")
        } catch {
            notes.append("\(name): \(error.localizedDescription)")
        }
    }
}
