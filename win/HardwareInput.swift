import Foundation
import GameController

/// Hardware keyboard and mouse, read through GameController and passed to Wine.
/// Based on Madeira's HardwareInput (GPL-3.0-or-later), much reduced.
///
/// Keyboard: GCKeyboard reports raw HID keys, one callback per physical key, so held
/// keys and modifier combinations reach the program as they happen.
///
/// Mouse: iPhone has no pointer of its own. A mouse works only with AssistiveTouch on,
/// which draws its own pointer, delivers the mouse's movement and buttons through GCMouse,
/// and turns each left click into a tap at its pointer. That pointer is what the user
/// sees, so it is treated as the truth: left clicks come from those taps (WineSurface),
/// each tap moves the program's cursor there (`sync(to:)`), and between taps the mouse's
/// movement moves it by the same amount the pointer moves.
@MainActor
final class HardwareInput {
    static let shared = HardwareInput()

    private static let move: UInt32 = 0x0001
    private static let absolute: UInt32 = 0x8000
    private static let wheel: UInt32 = 0x0800

    /// The program's cursor, in its screen pixels.
    private(set) var cursor = CGPoint(x: 640, y: 360)
    /// Windows screen pixels per point on screen, so movement matches AssistiveTouch's
    /// pointer. Set by WineSurface from how the program is fitted on screen.
    var pixelsPerPoint: CGFloat = 1

    private var started = false
    private var wheelRemainder: Double = 0

    private init() {}

    /// A tap or click landed here: the program's cursor follows, so movement continues
    /// from where the user sees the pointer.
    func sync(to point: CGPoint) {
        cursor = point
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { self.attach(keyboard: note.object as? GCKeyboard) }
        }
        center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { self.attach(mouse: note.object as? GCMouse) }
        }
        attach(keyboard: GCKeyboard.coalesced)
        GCMouse.mice().forEach { attach(mouse: $0) }
        log("started: keyboard=\(GCKeyboard.coalesced != nil) mice=\(GCMouse.mice().count)")
    }

    // MARK: Keyboard

    private func attach(keyboard: GCKeyboard?) {
        guard let keyboard, let input = keyboard.keyboardInput else { return }
        keyboard.handlerQueue = .main
        input.keyChangedHandler = { _, _, keyCode, pressed in
            guard let vk = Self.virtualKey(forHIDUsage: keyCode.rawValue) else { return }
            winios_post_key(vk, pressed ? 1 : 0)
        }
        log("keyboard connected")
    }

    // MARK: Mouse

    private func attach(mouse: GCMouse?) {
        guard let mouse, let input = mouse.mouseInput else { return }
        mouse.handlerQueue = .main
        input.mouseMovedHandler = { _, deltaX, deltaY in
            MainActor.assumeIsolated { self.moved(Double(deltaX), Double(deltaY)) }
        }
        // No left button handler: AssistiveTouch turns a left click into a tap at its
        // pointer, which WineSurface posts at the right position. Posting it here too
        // would click twice, the second time where the program's cursor happens to be.
        input.rightButton?.pressedChangedHandler = { _, _, pressed in
            MainActor.assumeIsolated { self.button(down: pressed ? 0x0008 : 0x0010) }
        }
        input.middleButton?.pressedChangedHandler = { _, _, pressed in
            MainActor.assumeIsolated { self.button(down: pressed ? 0x0020 : 0x0040) }
        }
        input.scroll.valueChangedHandler = { _, first, _ in
            // GCMouse reports the vertical wheel in the first value, negative away from
            // the user; Windows wants positive away from the user, in steps of 120.
            MainActor.assumeIsolated { self.scrolled(-Double(first)) }
        }
        log("mouse connected: \(mouse.vendorName ?? "unknown")")
    }

    private func moved(_ deltaX: Double, _ deltaY: Double) {
        var width: Int32 = 0, height: Int32 = 0
        winios_screen_size(&width, &height)
        // GameController's y points up; Windows' points down.
        cursor.x = min(max(cursor.x + deltaX * pixelsPerPoint, 0), CGFloat(max(width, 1) - 1))
        cursor.y = min(max(cursor.y - deltaY * pixelsPerPoint, 0), CGFloat(max(height, 1) - 1))
        post(Self.move | Self.absolute)
    }

    private func button(down flags: UInt32) {
        post(Self.move | Self.absolute | flags)
    }

    private func scrolled(_ amount: Double) {
        wheelRemainder += amount
        // One notch per whole unit; the rest waits for the next event.
        while abs(wheelRemainder) >= 1 {
            let step: Int32 = wheelRemainder > 0 ? 120 : -120
            wheelRemainder -= wheelRemainder > 0 ? 1 : -1
            winios_pointer(Int32(cursor.x), Int32(cursor.y), Self.wheel, UInt32(bitPattern: step))
        }
    }

    private func post(_ flags: UInt32) {
        winios_pointer(Int32(cursor.x), Int32(cursor.y), flags, 0)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[hw-input] \(message)\n".utf8))
    }

    // MARK: Key map

    /// Windows virtual-key code for a USB HID keyboard usage (page 0x07), or nil for a
    /// key Windows has no virtual key for. From Madeira's HardwareKeyMap.
    nonisolated static func virtualKey(forHIDUsage u: Int) -> Int32? {
        switch u {
        case 0x04...0x1D: return Int32(0x41 + (u - 0x04))   // A-Z
        case 0x1E...0x26: return Int32(0x31 + (u - 0x1E))   // 1-9
        case 0x27: return 0x30                              // 0
        case 0x28: return 0x0D                              // Return
        case 0x29: return 0x1B                              // Escape
        case 0x2A: return 0x08                              // Backspace
        case 0x2B: return 0x09                              // Tab
        case 0x2C: return 0x20                              // Space
        case 0x2D: return 0xBD                              // -
        case 0x2E: return 0xBB                              // =
        case 0x2F: return 0xDB                              // [
        case 0x30: return 0xDD                              // ]
        case 0x31, 0x32: return 0xDC                        // backslash, ISO #
        case 0x33: return 0xBA                              // ;
        case 0x34: return 0xDE                              // '
        case 0x35: return 0xC0                              // `
        case 0x36: return 0xBC                              // ,
        case 0x37: return 0xBE                              // .
        case 0x38: return 0xBF                              // /
        case 0x39: return 0x14                              // Caps Lock
        case 0x3A...0x45: return Int32(0x70 + (u - 0x3A))   // F1-F12
        case 0x46: return 0x2C                              // Print Screen
        case 0x47: return 0x91                              // Scroll Lock
        case 0x48: return 0x13                              // Pause
        case 0x49: return 0x2D                              // Insert
        case 0x4A: return 0x24                              // Home
        case 0x4B: return 0x21                              // Page Up
        case 0x4C: return 0x2E                              // Delete
        case 0x4D: return 0x23                              // End
        case 0x4E: return 0x22                              // Page Down
        case 0x4F: return 0x27                              // Right
        case 0x50: return 0x25                              // Left
        case 0x51: return 0x28                              // Down
        case 0x52: return 0x26                              // Up
        case 0x53: return 0x90                              // Num Lock
        case 0x54: return 0x6F                              // keypad /
        case 0x55: return 0x6A                              // keypad *
        case 0x56: return 0x6D                              // keypad -
        case 0x57: return 0x6B                              // keypad +
        case 0x58: return 0x0D                              // keypad Enter
        case 0x59...0x61: return Int32(0x61 + (u - 0x59))   // keypad 1-9
        case 0x62: return 0x60                              // keypad 0
        case 0x63: return 0x6E                              // keypad .
        case 0x64: return 0xE2                              // ISO < >
        case 0x65: return 0x5D                              // Menu
        case 0x68...0x73: return Int32(0x7C + (u - 0x68))   // F13-F24
        case 0xE0: return 0xA2                              // left Control
        case 0xE1: return 0xA0                              // left Shift
        case 0xE2: return 0xA4                              // left Alt (Option)
        case 0xE3: return 0x5B                              // left Windows (Command)
        case 0xE4: return 0xA3                              // right Control
        case 0xE5: return 0xA1                              // right Shift
        case 0xE6: return 0xA5                              // right Alt
        case 0xE7: return 0x5C                              // right Windows
        default: return nil
        }
    }
}
