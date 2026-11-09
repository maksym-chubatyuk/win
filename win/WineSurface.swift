import Metal
import QuartzCore
import SwiftUI
import UIKit

/// The area a program is drawn in. Direct3D output goes to this view's Metal layer, and
/// Madeira's compositor draws ordinary windows in a view above it. The compositor ignores
/// touches, so they land here and get forwarded to Wine as mouse input. The view also
/// takes keyboard input for the on-screen keyboard.
final class WineSurface: UIView, UIKeyInput {
    private static let vkReturn: Int32 = 0x0D
    private static let vkBack: Int32 = 0x08
    private static let vkTab: Int32 = 0x09

    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = false

        // DXMT presents here for a program that has no window layer of its own, and sets
        // the drawable size itself from then on. It only needs a non-zero size to start.
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.drawableSize = CGSize(width: 800, height: 600)
        // Keeps the program's shape; touches are mapped through the same fit below.
        metalLayer.contentsGravity = .resizeAspect
        madeira_display_set_layer(metalLayer)
    }

    /// The program's area within this view, and points per Windows pixel, when a
    /// Direct3D program fills it.
    private func programFit() -> (rect: CGRect, origin: CGPoint, scale: CGFloat)? {
        var x: Int32 = 0, y: Int32 = 0, width: Int32 = 0, height: Int32 = 0
        guard winios_game_client_rect(&x, &y, &width, &height) != 0, width > 0, height > 0 else { return nil }
        let scale = min(bounds.width / CGFloat(width), bounds.height / CGFloat(height))
        let shown = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        let rect = CGRect(x: (bounds.width - shown.width) / 2, y: (bounds.height - shown.height) / 2,
                          width: shown.width, height: shown.height)
        return (rect, CGPoint(x: CGFloat(x), y: CGFloat(y)), scale)
    }

    /// Windows screen pixels per point, so mouse movement matches AssistiveTouch's pointer.
    private func updateMouseScale() {
        if let fit = programFit() {
            HardwareInput.shared.pixelsPerPoint = 1 / fit.scale
            return
        }
        // Ordinary windows: the compositor fits the whole Windows screen in this view.
        var width: Int32 = 0, height: Int32 = 0
        winios_screen_size(&width, &height)
        guard width > 0, height > 0, bounds.width > 0, bounds.height > 0 else { return }
        HardwareInput.shared.pixelsPerPoint = 1 / min(bounds.width / CGFloat(width), bounds.height / CGFloat(height))
    }

    required init?(coder: NSCoder) {
        fatalError("WineSurface is only created in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateMouseScale()
        let area = convert(bounds, to: nil)
        winios_set_compositor_frame(area.minX, area.minY, area.width, area.height)
    }

    // MARK: Touch

    /// The Windows screen position under a touch.
    private func guestPoint(_ touch: UITouch) -> (Int32, Int32)? {
        // A program drawing with Direct3D fills this view, fitted to its client area.
        if let fit = programFit() {
            let location = touch.location(in: self)
            let x = (location.x - fit.rect.minX) / fit.scale
            let y = (location.y - fit.rect.minY) / fit.scale
            let width = fit.rect.width / fit.scale, height = fit.rect.height / fit.scale
            return (Int32(fit.origin.x + min(max(x, 0), width - 1)),
                    Int32(fit.origin.y + min(max(y, 0), height - 1)))
        }

        // Otherwise the compositor knows where it placed the program's windows.
        let location = touch.location(in: nil)
        var x: Int32 = 0, y: Int32 = 0
        guard winios_desktop_point_from_window(location.x, location.y, &x, &y) != 0 else { return nil }
        return (x, y)
    }

    // A finger's touch and an AssistiveTouch click arrive the same way, at the position the
    // user sees, so both also move the program's cursor there (HardwareInput.sync).

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let (x, y) = guestPoint(touch) else { return }
        updateMouseScale()
        HardwareInput.shared.sync(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
        winios_post_touch_down(x, y)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let (x, y) = guestPoint(touch) else { return }
        HardwareInput.shared.sync(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
        winios_post_touch_move(x, y)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let (x, y) = guestPoint(touch) else { return }
        HardwareInput.shared.sync(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
        winios_post_touch_up(x, y)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }

    func insertText(_ text: String) {
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": pressKey(Self.vkReturn)
            case "\t": pressKey(Self.vkTab)
            default: postText(scalar)
            }
        }
    }

    func deleteBackward() {
        pressKey(Self.vkBack)
    }

    func pressKeyForTest(_ vk: Int32) {
        pressKey(vk)
    }

    private func pressKey(_ vk: Int32) {
        winios_post_key(vk, 1)
        winios_post_key(vk, 0)
    }

    private func postText(_ scalar: UnicodeScalar) {
        // The queue only refuses when it is nearly full, so a short retry is enough.
        guard winios_try_post_text(scalar.value, 0, 0, 5) == 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.postText(scalar)
        }
    }
}

struct WineSurfaceView: UIViewRepresentable {
    let surface: WineSurface

    func makeUIView(context: Context) -> WineSurface { surface }
    func updateUIView(_ uiView: WineSurface, context: Context) {}
}
