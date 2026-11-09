import SwiftUI
import UniformTypeIdentifiers

/// The program picker the app opens on: imported programs, plus a way to add more.
struct LibraryView: View {
    /// A debugger is attached from the Mac (scripts/jit-run.sh).
    let debuggerAttached: Bool
    let onRun: (WindowsProgram) -> Void
    let onRunNotepad: () -> Void

    @State private var programs = [WindowsProgram]()
    /// The runtime log of the last program run (WineHost.m starts a new one with each run).
    @State private var lastLog: URL?
    @State private var pickerTypes: [UTType]?
    @State private var importingPairingFile = false
    @State private var hasPairingFile = BuiltInJIT.hasPairingFile
    @State private var setupMessage: String?
    @State private var isCheckingSetup = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var programToRemove: WindowsProgram?
    /// The controller layout being edited: for all programs, or for one.
    @State private var editingLayout: LayoutTarget?
    @AppStorage(ScreenResolution.storageKey) private var resolution = ScreenResolution.defaultChoice.storageValue

    var body: some View {
        NavigationStack {
            List {
                if !canRun {
                    Section {
                        Label("To run programs, set up Run Without a Mac below. iOS only allows generated code while a debugger is attached.",
                              systemImage: "cable.connector")
                            .font(.footnote)
                    }
                }

                Section("Your programs") {
                    if programs.isEmpty {
                        Text("Nothing here yet. Tap + to add a Windows program from Files.")
                            .foregroundStyle(.secondary)
                    }
                    // Removing: swipe left, press and hold, or Edit in the top bar. All
                    // three ask first, as the whole folder goes.
                    ForEach(programs) { program in
                        ProgramRow(program: program, canRun: canRun) { onRun(program) }
                            .swipeActions {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    programToRemove = program
                                }
                            }
                            .contextMenu {
                                Button("Controller Layout", systemImage: "gamecontroller") {
                                    editingLayout = LayoutTarget(program: program)
                                }
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    programToRemove = program
                                }
                            }
                    }
                    .onDelete { offsets in
                        programToRemove = offsets.first.map { programs[$0] }
                    }
                }

                Section("Included with Wine") {
                    Button("Notepad", systemImage: "doc.text", action: onRunNotepad)
                        .disabled(!canRun)
                }

                runWithoutMacSection

                if let lastLog {
                    Section {
                        ShareLink(item: lastLog) {
                            Label("Share Log", systemImage: "square.and.arrow.up")
                        }
                    } footer: {
                        Text("The log of the last program run, madeira-log.txt. Attach it when you report a problem.")
                    }
                }

                Section {
                    Text("Running a program takes about 25 seconds to start. To run a different one, close the app and start it again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Programs")
            .toolbar {
                // The screen size Windows programs see. A game with its own resolution
                // setting may need it changed in the game as well.
                ToolbarItem(placement: .topBarLeading) {
                    Menu("Resolution", systemImage: "display") {
                        Picker("Resolution", selection: $resolution) {
                            ForEach(ScreenResolution.choices) { choice in
                                Text(choice.label()).tag(choice.storageValue)
                            }
                        }
                        Text("Lower is faster. Games with their own resolution setting may need it changed in the game too.")
                    }
                    .accessibilityHint("Chooses the screen size Windows programs see")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Controller Layout", systemImage: "gamecontroller") {
                        editingLayout = LayoutTarget(program: nil)
                    }
                    .accessibilityHint("Arranges the on-screen controller for all programs")
                }
                if !programs.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("Add", systemImage: "plus") {
                        Button("Choose .exe File", systemImage: "doc") { pick([.data]) }
                        Button("Choose Folder", systemImage: "folder") { pick([.folder]) }
                    }
                    .disabled(isImporting)
                }
            }
            .overlay {
                if isImporting {
                    ProgressView("Copying into Wine...")
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
            }
            .fileImporter(isPresented: Binding(get: { pickerTypes != nil || importingPairingFile },
                                               set: { if !$0 { pickerTypes = nil; importingPairingFile = false } }),
                          allowedContentTypes: importingPairingFile ? [.propertyList, .data] : (pickerTypes ?? [.data])) { result in
                let forPairing = importingPairingFile
                switch result {
                case .success(let url) where forPairing: importPairingFile(from: url)
                case .success(let url): importProgram(from: url)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .alert("Run Without a Mac", isPresented: Binding(get: { setupMessage != nil },
                                                             set: { if !$0 { setupMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(setupMessage ?? "")
            }
            .alert("Could not add program", isPresented: Binding(get: { errorMessage != nil },
                                                                  set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog(removalTitle, isPresented: Binding(get: { programToRemove != nil },
                                                                    set: { if !$0 { programToRemove = nil } }),
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) { removeSelectedProgram() }
            } message: {
                Text("This deletes the whole folder from the app, along with any saved data inside it.")
            }
            .task { await reload() }
            .fullScreenCover(item: $editingLayout) { target in
                TouchLayoutEditor(programID: target.program?.layoutID, programName: target.program?.fileName)
            }
        }
    }

    private var canRun: Bool { debuggerAttached || hasPairingFile }

    private var runWithoutMacSection: some View {
        Section {
            LabeledContent("Pairing file", value: hasPairingFile ? "Imported" : "Not imported")
            Button(hasPairingFile ? "Replace Pairing File" : "Import Pairing File", systemImage: "key") {
                importingPairingFile = true
            }
            Button("Check Setup", systemImage: "checkmark.circle") { checkSetup() }
                .disabled(!hasPairingFile || isCheckingSetup)
            Button("Reset Developer Disk Image", systemImage: "arrow.counterclockwise") { resetDiskImage() }
                .disabled(isCheckingSetup)
        } header: {
            Text("Run Without a Mac")
        } footer: {
            Text("Connect LocalDevVPN before running a program, on Wi-Fi or with no network; it does not work over cellular data. The pairing file is made once on a computer with iloader, and stops working if you change this iPhone's passcode.")
        }
    }

    private func importPairingFile(from url: URL) {
        do {
            try BuiltInJIT.importPairingFile(from: url)
            hasPairingFile = true
        } catch {
            setupMessage = error.localizedDescription
        }
    }

    private func checkSetup() {
        isCheckingSetup = true
        Task {
            let response = await BuiltInJIT.checkSetup()
            setupMessage = response.message
            isCheckingSetup = false
        }
    }

    private func resetDiskImage() {
        isCheckingSetup = true
        Task {
            setupMessage = await BuiltInJIT.resetDiskImage().message
            isCheckingSetup = false
        }
    }

    private var removalTitle: String {
        "Remove \(programToRemove?.folderName ?? "program")?"
    }

    private func pick(_ types: [UTType]) {
        pickerTypes = types
    }

    private func reload() async {
        programs = await Task.detached { ProgramLibrary.programs() }.value
        let log = URL.documentsDirectory.appending(path: "madeira-log.txt")
        lastLog = FileManager.default.fileExists(atPath: log.path(percentEncoded: false)) ? log : nil
    }

    private func importProgram(from url: URL) {
        isImporting = true
        Task {
            do {
                try await Task.detached { try ProgramLibrary.importItem(from: url) }.value
            } catch {
                errorMessage = error.localizedDescription
            }
            await reload()
            isImporting = false
        }
    }

    private func removeSelectedProgram() {
        guard let program = programToRemove else { return }
        do {
            try ProgramLibrary.remove(program)
        } catch {
            errorMessage = error.localizedDescription
        }
        Task { await reload() }
    }
}

/// Whose on-screen controller layout is being edited; nil for all programs.
private struct LayoutTarget: Identifiable {
    let program: WindowsProgram?
    var id: String { program?.id ?? "" }
}

private struct ProgramRow: View {
    let program: WindowsProgram
    let canRun: Bool
    let onRun: () -> Void

    var body: some View {
        Button(action: onRun) {
            VStack(alignment: .leading, spacing: 2) {
                Text(program.fileName)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!canRun || !program.architecture.canRun)
    }

    private var detail: String {
        var parts = [program.folderName, program.architecture.label]
        if program.isConsole { parts.append("console") }
        if !program.architecture.canRun { parts.append("not supported yet") }
        return parts.joined(separator: " · ")
    }
}
