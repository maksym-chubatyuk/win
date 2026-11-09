// The built-in JIT helper: an app extension that win starts when it needs JIT without a
// Mac. A process cannot debug itself, so this separate process attaches StikJIT's debugger
// to win and runs madeira-jit.js, which serves the same requests as scripts/jit_host.py.
// Based on Madeira's MadeiraJITHelper (GPL-3.0-or-later); StikJIT is MPL-2.0.

import Foundation
import StikJIT

/// One request from win, as JSON in the extension request's first item.
/// Keep in sync with JITHelperRequest in win/BuiltInJIT.swift.
struct JITHelperRequest: Codable {
    static let itemKey = "win-jit-request"

    enum Operation: String, Codable {
        case prepare, enable, resetDiskImage
    }

    let operation: Operation
    let targetPID: Int32?
    let pairingData: Data?
    let scriptBase64: String?

    struct Response: Codable {
        static let itemKey = "win-jit-response"
        let success: Bool
        let message: String
    }
}

private enum JITWork {
    /// One request at a time; an enable request lasts as long as the debugger does.
    static let queue = DispatchQueue(label: "winnny.win.jit-helper")

    static func handle(_ request: JITHelperRequest) -> JITHelperRequest.Response {
        let manager = FileManager.default
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            if request.operation == .resetDiskImage {
                try StikJIT.resetCachedDDI(at: paths)
                return .init(success: true, message: "The Developer Disk Image will be downloaded again on the next check.")
            }

            guard let pairingData = request.pairingData, !pairingData.isEmpty else {
                return .init(success: false, message: "No pairing file was provided.")
            }
            // StikJIT reads the pairing file from disk; it only exists for this request.
            let pairingURL = root.appendingPathComponent("pairing-\(UUID().uuidString).plist")
            try pairingData.write(to: pairingURL, options: [.atomic, .completeFileProtection])
            defer { try? manager.removeItem(at: pairingURL) }

            switch request.operation {
            case .prepare:
                let readiness = StikJIT.prepareDevice(pairingFile: pairingURL, paths: paths,
                                                      progress: { NSLog("[win-jit] prepare: %@", String(describing: $0)) })
                switch readiness {
                case .ready:
                    return .init(success: true, message: "Ready. LocalDevVPN is reachable and the Developer Disk Image is mounted.")
                case .unreachable(let reason), .preparationFailed(let reason):
                    return .init(success: false, message: reason)
                @unknown default:
                    return .init(success: false, message: "StikJIT returned an unknown state.")
                }

            case .enable:
                guard let pid = request.targetPID, let script = request.scriptBase64, !script.isEmpty else {
                    return .init(success: false, message: "The request had no process or script.")
                }
                try StikJIT.enableJIT(targetPID: pid, pairingFile: pairingURL, ddiPaths: paths,
                                      script: .customBase64(script), forceScript: true,
                                      preparationProgress: { NSLog("[win-jit] prepare: %@", String(describing: $0)) },
                                      progress: { NSLog("[win-jit] %@", $0) })
                return .init(success: true, message: "The debugger detached from win.")

            case .resetDiskImage:
                preconditionFailure("handled above")
            }
        } catch {
            return .init(success: false, message: error.localizedDescription)
        }
    }
}

/// NSExtensionPrincipalClass in Info.plist. An enable request completes only once the
/// script has detached, so this process lives exactly as long as the debugger.
@objc(WinJITHelperHandler)
final class WinJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo
        let data = info?[JITHelperRequest.itemKey] as? Data
        let request = data.flatMap { try? JSONDecoder().decode(JITHelperRequest.self, from: $0) }

        JITWork.queue.async {
            let response = request.map(JITWork.handle)
                ?? .init(success: false, message: "The JIT helper received no request.")
            let item = NSExtensionItem()
            item.userInfo = [JITHelperRequest.Response.itemKey: (try? JSONEncoder().encode(response)) ?? Data()]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}
