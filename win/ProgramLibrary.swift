import Foundation

/// A Windows program imported into the Wine prefix, at C:\Programs\<folder>\...
nonisolated struct WindowsProgram: Identifiable, Hashable, Sendable {
    enum Architecture: Sendable {
        case x64, arm64, x86, unknown

        var label: String {
            switch self {
            case .x64: "x86-64"
            case .arm64: "ARM64"
            case .x86: "32-bit x86"
            case .unknown: "Unknown type"
            }
        }

        /// 32-bit programs run through Wine's WoW64 layer with FEX translating the x86
        /// code; that needs the i386 DLL set (third_party/madeira/app/Madeira/i386-windows,
        /// built by build/wine-i386/build.sh) in the app.
        var canRun: Bool {
            switch self {
            case .x64, .arm64: true
            case .x86: Self.hasI386Set
            case .unknown: false
            }
        }

        static let hasI386Set = FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL.appending(path: "i386-windows/ntdll.dll").path(percentEncoded: false))
    }

    let fileName: String
    let folderName: String
    let windowsPath: String
    let windowsFolder: String
    let architecture: Architecture
    let isConsole: Bool
    let folderURL: URL

    var id: String { windowsPath }

    /// Which on-screen controller layout it uses (TouchLayout), if it has its own.
    var layoutID: String { folderName }
}

nonisolated enum ProgramLibraryError: LocalizedError {
    case notAnExecutable(String)
    case notAWindowsProgram(String)
    case noExecutableInFolder(String)

    var errorDescription: String? {
        switch self {
        case .notAnExecutable(let name):
            "\(name) is not an .exe file."
        case .notAWindowsProgram(let name):
            "\(name) is not a Windows program."
        case .noExecutableInFolder(let name):
            "The folder \(name) has no .exe file in it."
        }
    }
}

nonisolated enum ProgramLibrary {
    private static let prefix = URL.documentsDirectory.appending(path: "wine")
    static let root = prefix.appending(path: "drive_c/Programs")

    // MARK: Listing

    static func programs() -> [WindowsProgram] {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return [] }

        var found = [WindowsProgram]()
        for folder in folders {
            guard let walker = manager.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                  options: .skipsHiddenFiles) else { continue }
            for case let file as URL in walker where file.pathExtension.lowercased() == "exe" {
                if let program = describe(file: file, topFolder: folder) { found.append(program) }
            }
        }
        return found.sorted {
            let order = $0.folderName.localizedStandardCompare($1.folderName)
            return order == .orderedSame ? $0.windowsPath < $1.windowsPath : order == .orderedAscending
        }
    }

    private static func describe(file: URL, topFolder: URL) -> WindowsProgram? {
        let parts = Array(file.standardizedFileURL.pathComponents
            .dropFirst(root.standardizedFileURL.pathComponents.count))
        // These characters cannot appear in a Windows path or survive its command line.
        guard !parts.isEmpty, !parts.contains(where: { $0.contains("\"") || $0.contains("\\") }) else {
            return nil
        }
        let header = readHeader(of: file)
        return WindowsProgram(
            fileName: file.lastPathComponent,
            folderName: topFolder.lastPathComponent,
            windowsPath: "C:\\Programs\\" + parts.joined(separator: "\\"),
            windowsFolder: "C:\\Programs\\" + parts.dropLast().joined(separator: "\\"),
            architecture: header?.architecture ?? .unknown,
            isConsole: header?.isConsole ?? false,
            folderURL: topFolder)
    }

    // MARK: Reading the PE header

    private static func readHeader(of file: URL) -> (architecture: WindowsProgram.Architecture, isConsole: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), data.count >= 0x40 else { return nil }

        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= data.count else { return nil }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        guard data[0] == 0x4D, data[1] == 0x5A,      // "MZ"
              let low = u16(0x3C), let high = u16(0x3E) else { return nil }
        let pe = low | high << 16
        guard pe + 4 <= data.count, data[pe] == 0x50, data[pe + 1] == 0x45,   // "PE"
              let machine = u16(pe + 4) else { return nil }

        let architecture: WindowsProgram.Architecture = switch machine {
        case 0x8664: .x64
        case 0xAA64, 0xA641: .arm64
        case 0x014C: .x86
        default: .unknown
        }
        // The subsystem sits 68 bytes into the optional header, in both 32 and 64-bit PEs.
        let subsystem = u16(pe + 24 + 68)
        return (architecture, subsystem == 3)
    }

    // MARK: Importing

    /// Copies an .exe, or a folder holding one, into the prefix. Runs off the main thread.
    static func importItem(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        // The prefix has to exist first, because seeding it later expects to create it.
        win_wine_prepare_prefix()
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            do {
                try copy(url)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
    }

    private static func copy(_ source: URL) throws {
        let manager = FileManager.default
        let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

        if isFolder {
            let hasExecutable = manager.enumerator(at: source, includingPropertiesForKeys: nil)?
                .contains { ($0 as? URL)?.pathExtension.lowercased() == "exe" } ?? false
            guard hasExecutable else { throw ProgramLibraryError.noExecutableInFolder(source.lastPathComponent) }
        } else {
            guard source.pathExtension.lowercased() == "exe" else {
                throw ProgramLibraryError.notAnExecutable(source.lastPathComponent)
            }
            guard readHeader(of: source) != nil else {
                throw ProgramLibraryError.notAWindowsProgram(source.lastPathComponent)
            }
        }

        // Copied under a hidden name first, so a failed copy never shows up as a program.
        let holding = root.appending(path: ".import-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: holding) }

        if isFolder {
            try manager.copyItem(at: source, to: holding)
        } else {
            try manager.createDirectory(at: holding, withIntermediateDirectories: false)
            try manager.copyItem(at: source, to: holding.appending(path: source.lastPathComponent))
        }

        let baseName = safeFolderName(source.deletingPathExtension().lastPathComponent)
        try manager.moveItem(at: holding, to: unusedFolder(named: baseName))
    }

    /// A name that is simple to quote on a Windows command line.
    private static func safeFolderName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "_" })
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty ? "Program" : cleaned
    }

    private static func unusedFolder(named name: String) -> URL {
        var candidate = root.appending(path: name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = root.appending(path: "\(name) \(number)")
            number += 1
        }
        return candidate
    }

    // MARK: Removing

    static func remove(_ program: WindowsProgram) throws {
        try FileManager.default.removeItem(at: program.folderURL)
    }
}
