import SwiftUI
import UIKit

struct ContentView: View {
    private enum Screen {
        case library, console, program
    }

    @State private var screen = Screen.library
    @State private var debuggerReady = false
    @State private var title = ""
    @State private var status = "Starting Wine..."
    @State private var output = ""
    @State private var surface = WineSurface()
    /// Controller mode (the screen is an Xbox controller) or mouse mode; mouse until
    /// asked for, and remembered after that.
    @AppStorage("touchControllerVisible") private var controllerVisible = false
    @State private var programIsShowing = false
    @State private var launchError: String?
    /// The running program's TouchLayout key (its folder), nil for Notepad.
    @State private var programID: String?

    var body: some View {
        Group {
            switch screen {
            case .library:
                LibraryView(debuggerAttached: debuggerReady,
                            onRun: { run($0) },
                            onRunNotepad: {
                                programID = nil
                                launch(exe: "notepad.exe", arguments: nil, folder: nil, console: false)
                            })
            case .console:
                consoleView
            case .program:
                programView
            }
        }
        .task { await prepare() }
        // A program's screen is landscape; the menus and console output follow the phone.
        // The lock is on before Wine starts (600 ms after this switch), so the program's
        // window is laid out once, at its final size.
        .onChange(of: screen, initial: true) { _, now in
            OrientationLock.landscape(now == .program)
        }
        .alert("Could not start", isPresented: Binding(get: { launchError != nil },
                                                       set: { if !$0 { launchError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(launchError ?? "")
        }
    }

    private var consoleView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title2.bold())
                Text(status)
                Text(output)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var programView: some View {
        ZStack {
            WineSurfaceView(surface: surface)
                .ignoresSafeArea()
            if !programIsShowing {
                ProgressView(status)
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
        // The mode and keyboard buttons and the controller live in ControlsWindow, above
        // the view Winios.m puts the program's windows in.
        .onChange(of: programIsShowing, initial: true) { _, showing in
            ControlsWindow.show(showing, controllerMode: controllerVisible,
                                layout: TouchLayout.load(for: programID),
                                onMode: { controllerVisible = $0 },
                                onKeyboard: {
                                    if surface.isFirstResponder {
                                        surface.resignFirstResponder()
                                    } else {
                                        surface.becomeFirstResponder()
                                    }
                                })
        }
        .onChange(of: controllerVisible, initial: true) { _, on in
            ControlsWindow.setControllerMode(on)
            GamepadBridge.shared.touchVisible = on
        }
        .onDisappear { ControlsWindow.show(false, controllerMode: false, onMode: { _ in }, onKeyboard: {}) }
    }

    /// Waits for the debugger, then follows any choice scripts/jit-run.sh made. Without
    /// one, the library stays up and the debugger stays attached until a program is chosen.
    private func prepare() async {
        let environment = ProcessInfo.processInfo.environment
        WineAutotest.prepare()
        while !win_jit_debugger_flag() {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
        debuggerReady = true
        if WineAutotest.isEnabled { await WineAutotest.testHelperRoundTrip() }

        if environment["WIN_SHOW_PAD"] == "1" { controllerVisible = true }
        if let exe = environment["WIN_EXE"] {
            start(exe: exe, arguments: environment["WIN_ARGS"], folder: nil,
                  console: environment["WIN_CONSOLE"] == "1")
        } else if WineAutotest.isEnabled, let program = await WineAutotest.preparedProgram() {
            run(program)
        }
    }

    private func run(_ program: WindowsProgram) {
        programID = program.layoutID
        launch(exe: program.windowsPath, arguments: nil, folder: program.windowsFolder,
               console: program.isConsole, name: program.fileName)
    }

    /// Uses the Mac's debugger when one is attached, and otherwise attaches the built-in
    /// one first. Wine asks for executable memory as it starts, so it has to wait for that.
    private func launch(exe: String, arguments: String?, folder: String?, console: Bool, name: String? = nil) {
        if BuiltInJIT.isDebuggerAttached() {
            start(exe: exe, arguments: arguments, folder: folder, console: console, name: name)
            return
        }
        title = name ?? exe
        status = "Connecting the debugger. The first time can take a minute."
        screen = console ? .console : .program
        Task {
            do {
                try await BuiltInJIT.attachDebugger()
                start(exe: exe, arguments: arguments, folder: folder, console: console, name: name)
            } catch {
                screen = .library
                launchError = error.localizedDescription
            }
        }
    }

    private func start(exe: String, arguments: String?, folder: String?, console: Bool, name: String? = nil) {
        title = name ?? exe
        status = "Preparing \(title). The screen freezes for about 15 seconds while memory is set up; that is expected."
        UIApplication.shared.isIdleTimerDisabled = true
        HardwareInput.shared.start()
        GamepadBridge.shared.start()
        screen = console ? .console : .program
        Task {
            // The debugger pauses the whole app while it sets up executable memory, so the
            // message above has to be on screen before that starts.
            try? await Task.sleep(for: .milliseconds(600))
            let screen = ScreenResolution.current
            win_wine_start(exe, arguments, folder,
                           console ? 0 : Int32(screen.width),
                           console ? 0 : Int32(screen.height))
            if WineAutotest.isEnabled {
                Task { await WineAutotest.run(isConsole: console, surface: surface) }
            }
            await followWine(console: console)
        }
    }

    private func followWine(console: Bool) async {
        let outputFile = URL.documentsDirectory.appending(path: "wine-output.txt")
        var exitCode: Int32 = 0
        while !win_wine_finished(&exitCode) {
            if console {
                // Only a console program's output is shown. A game can print a lot, and
                // re-reading the whole file twice a second costs it time for nothing.
                output = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? output
            } else if !programIsShowing {
                // Either a window was drawn, or Direct3D is presenting.
                programIsShowing = winios_surface_present_count() > 0 || madeira_frame_count() > 0
            }
            try? await Task.sleep(for: .milliseconds(programIsShowing ? 2000 : 500))
        }
        output = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? output
        // The first program can be a launcher stub that exits normally after starting the
        // real one, so its exit code says little; the runtime log has the full story.
        status = "Wine finished with exit code \(exitCode)."
        programIsShowing = false
    }
}

#Preview {
    ContentView()
}
