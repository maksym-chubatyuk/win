import Darwin
import Foundation
import Security

/// One request to winJITHelper, as JSON in the extension request's first item.
/// Keep in sync with JITHelperRequest in winJITHelper/JITHelper.swift.
nonisolated struct JITHelperRequest: Codable, Sendable {
    static let itemKey = "win-jit-request"

    enum Operation: String, Codable, Sendable {
        case prepare, enable, resetDiskImage
    }

    let operation: Operation
    let targetPID: Int32?
    let pairingData: Data?
    let scriptBase64: String?

    struct Response: Codable, Sendable {
        static let itemKey = "win-jit-response"
        let success: Bool
        let message: String
    }
}

nonisolated enum BuiltInJITError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

/// JIT without a Mac. The bundled winJITHelper extension attaches StikJIT's debugger to
/// this app through LocalDevVPN, using this iPhone's pairing file, and runs madeira-jit.js,
/// which answers the same requests scripts/jit_host.py answers from the Mac.
@MainActor
enum BuiltInJIT {
    private static let helperFile = "winJITHelper.appex"
    private static let keychainService = "winnny.win.pairing-file"
    private static let keychainAccount = "this-device"

    // MARK: Pairing file

    /// A file copied into Documents (for example from the Mac with devicectl) is moved
    /// into the Keychain here, because it is a credential for the iPhone itself.
    private static var droppedPairingFile: URL {
        URL.documentsDirectory.appending(path: "pairingFile.plist")
    }

    static var hasPairingFile: Bool {
        adoptDroppedPairingFile()
        return pairingData() != nil
    }

    static func importPairingFile(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try savePairingData(try Data(contentsOf: url))
    }

    static func forgetPairingFile() {
        SecItemDelete(keychainQuery as CFDictionary)
    }

    private static func adoptDroppedPairingFile() {
        guard let data = try? Data(contentsOf: droppedPairingFile) else { return }
        if (try? savePairingData(data)) != nil {
            try? FileManager.default.removeItem(at: droppedPairingFile)
        }
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    private static func pairingData() -> Data? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func savePairingData(_ data: Data) throws {
        // A pairing file is a property list dictionary; anything else is the wrong file.
        guard (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any] else {
            throw BuiltInJITError.message("That is not a pairing file. Pairing files are .plist files made by iloader.")
        }
        SecItemDelete(keychainQuery as CFDictionary)
        var item = keychainQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BuiltInJITError.message("The pairing file could not be saved in the Keychain (error \(status)).")
        }
    }

    // MARK: Checks

    /// Whether LocalDevVPN's loopback reaches this iPhone's lockdownd. Over cellular data
    /// the tunnel does not work, so this fails there.
    nonisolated static func isLoopbackReachable(timeout: TimeInterval = 0.5) -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(62078).bigEndian
        guard inet_pton(AF_INET, "10.7.0.1", &address.sin_addr) == 1 else { return false }

        let socketFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        _ = fcntl(socketFD, F_SETFL, fcntl(socketFD, F_GETFL, 0) | O_NONBLOCK)

        let started = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var poller = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1000)) == 1 else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &socketError, &length)
        return socketError == 0
    }

    /// Whether a debugger is attached to this process right now. CS_DEBUGGED stays set
    /// after a debugger leaves, so it alone cannot say that.
    nonisolated static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return false }
        return info.kp_proc.p_flag & P_TRACED != 0
    }

    // MARK: Requests

    /// Downloads and mounts the Developer Disk Image if needed, and confirms the route.
    static func checkSetup() async -> JITHelperRequest.Response {
        guard let pairing = pairingData() else {
            return .init(success: false, message: "Import this iPhone's pairing file first.")
        }
        guard isLoopbackReachable() else { return .init(success: false, message: vpnHint) }
        return await finalResponse(.init(operation: .prepare, targetPID: nil, pairingData: pairing, scriptBase64: nil))
    }

    static func resetDiskImage() async -> JITHelperRequest.Response {
        await finalResponse(.init(operation: .resetDiskImage, targetPID: nil, pairingData: nil, scriptBase64: nil))
    }

    /// Attaches the built-in debugger and returns once it is serving requests. Executable
    /// memory is requested only after this, because an unanswered request crashes the app.
    static func attachDebugger() async throws {
        guard let pairing = pairingData() else {
            throw BuiltInJITError.message("Import this iPhone's pairing file first, under Run Without a Mac.")
        }
        guard isLoopbackReachable() else { throw BuiltInJITError.message(vpnHint) }
        guard let scriptURL = Bundle.main.url(forResource: "madeira-jit", withExtension: "js"),
              let script = try? Data(contentsOf: scriptURL) else {
            throw BuiltInJITError.message("The JIT script is missing from this build.")
        }

        let request = JITHelperRequest(operation: .enable, targetPID: getpid(), pairingData: pairing,
                                       scriptBase64: script.base64EncodedString())
        var finished: Result<JITHelperRequest.Response, Error>?
        try send(request) { finished = $0 }

        // The helper answers only when the debugger leaves, so attachment is watched here.
        // Mounting the disk image the first time can take a while.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if isDebuggerAttached() && win_jit_debugger_flag() { return }
            switch finished {
            case .failure(let error)?:
                throw error
            case .success(let response)?:
                throw BuiltInJITError.message(response.success
                    ? "The debugger left before it could be used. Try again."
                    : response.message)
            case nil:
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw BuiltInJITError.message("The debugger did not attach within two minutes. Check that LocalDevVPN is connected, then try again.")
    }

    private static let vpnHint = "LocalDevVPN is not reachable. Open LocalDevVPN and connect, using Wi-Fi or no network; it does not work over cellular data."

    private static func finalResponse(_ request: JITHelperRequest) async -> JITHelperRequest.Response {
        await withCheckedContinuation { continuation in
            do {
                try send(request) { result in
                    switch result {
                    case .success(let response): continuation.resume(returning: response)
                    case .failure(let error): continuation.resume(returning: .init(success: false, message: error.localizedDescription))
                    }
                }
            } catch {
                continuation.resume(returning: .init(success: false, message: error.localizedDescription))
            }
        }
    }

    // MARK: Starting the helper

    /// Requests that have started and not finished, kept alive until they do.
    private static var running: [HelperRequest] = []

    private static func send(_ request: JITHelperRequest,
                             completion: @escaping (Result<JITHelperRequest.Response, Error>) -> Void) throws {
        guard let url = Bundle.main.builtInPlugInsURL?.appending(path: helperFile),
              let identifier = Bundle(url: url)?.bundleIdentifier else {
            throw BuiltInJITError.message("The JIT helper is missing from this installation.")
        }
        // NSExtension is private API in ExtensionFoundation: the calls LiveContainer and
        // Madeira use to start an app extension of their own.
        if NSClassFromString("NSExtension") == nil {
            dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW)
        }
        guard let extensionClass = NSClassFromString("NSExtension") else {
            throw BuiltInJITError.message("iOS did not provide the extension API the JIT helper needs.")
        }
        let factory = unsafeBitCast(extensionClass as AnyObject, to: NSExtensionClassShim.self)
        let found = try factory.extension(withIdentifier: identifier)
        let data = try JSONEncoder().encode(request)

        let helper = HelperRequest(extension: found) { result in completion(result) }
        running.append(helper)
        helper.begin(data: data)
    }

    fileprivate static func finished(_ helper: HelperRequest) {
        running.removeAll { $0 === helper }
    }
}

@objc private protocol NSExtensionClassShim {
    @objc(extensionWithIdentifier:error:)
    func `extension`(withIdentifier identifier: String) throws -> AnyObject
}

@objc private protocol NSExtensionShim {
    @objc(beginExtensionRequestWithInputItems:completion:)
    func beginExtensionRequest(withInputItems items: [Any], completion: @escaping (NSUUID?) -> Void)
    @objc(setRequestCompletionBlock:)
    func setRequestCompletionBlock(_ block: @escaping (NSUUID?, [Any]?) -> Void)
    @objc(setRequestCancellationBlock:)
    func setRequestCancellationBlock(_ block: @escaping (NSUUID?, NSError?) -> Void)
    @objc(setRequestInterruptionBlock:)
    func setRequestInterruptionBlock(_ block: @escaping (NSUUID?) -> Void)
}

/// One request to the helper, from its start to its single result.
@MainActor
private final class HelperRequest {
    private let shim: NSExtensionShim
    private let `extension`: AnyObject   // kept alive for the request
    private var completion: ((Result<JITHelperRequest.Response, Error>) -> Void)?

    init(extension found: AnyObject, completion: @escaping (Result<JITHelperRequest.Response, Error>) -> Void) {
        self.extension = found
        self.shim = unsafeBitCast(found, to: NSExtensionShim.self)
        self.completion = completion
    }

    func begin(data: Data) {
        // The blocks can arrive on any queue; results are handled on the main thread.
        shim.setRequestCompletionBlock { [weak self] _, items in
            let info = (items?.first as? NSExtensionItem)?.userInfo
            let payload = info?[JITHelperRequest.Response.itemKey] as? Data
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.returned(payload) } }
        }
        shim.setRequestCancellationBlock { [weak self] _, error in
            let reason = error?.localizedDescription ?? "the request was cancelled"
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.end(.failure(BuiltInJITError.message("The JIT helper stopped: \(reason)")))
            } }
        }
        shim.setRequestInterruptionBlock { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.end(.failure(BuiltInJITError.message("The JIT helper stopped unexpectedly. Try again.")))
            } }
        }
        let item = NSExtensionItem()
        item.userInfo = [JITHelperRequest.itemKey: data]
        shim.beginExtensionRequest(withInputItems: [item]) { [weak self] identifier in
            guard identifier == nil else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.end(.failure(BuiltInJITError.message("The JIT helper did not start.")))
            } }
        }
    }

    private func returned(_ payload: Data?) {
        guard let payload,
              let response = try? JSONDecoder().decode(JITHelperRequest.Response.self, from: payload) else {
            end(.failure(BuiltInJITError.message("The JIT helper finished without an answer.")))
            return
        }
        end(.success(response))
    }

    private func end(_ result: Result<JITHelperRequest.Response, Error>) {
        guard let completion else { return }   // only the first result counts
        self.completion = nil
        BuiltInJIT.finished(self)
        completion(result)
    }
}
