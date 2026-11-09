import UIKit

/// The mode and keyboard buttons, and the on-screen controller, in a window of their own
/// above the app's. Madeira's Winios.m adds Wine's windows and the game's Metal layer as a
/// view straight onto the app window, above everything SwiftUI draws, so controls placed
/// in SwiftUI would end up under a full-screen game.
///
/// Mouse mode: only the two buttons take touches; everything else falls through to the
/// program as the pointer. Controller mode: the whole screen is the controller.
@MainActor
final class ControlsWindow: UIWindow {
    private static var current: ControlsWindow?

    /// Shows the window over the app's scene, or removes it.
    static func show(_ visible: Bool, controllerMode: Bool, layout: TouchLayout = TouchLayout.load(for: nil),
                     onMode: @escaping (Bool) -> Void, onKeyboard: @escaping () -> Void) {
        guard visible else {
            current?.controller.releaseAll()
            current?.isHidden = true
            current = nil
            return
        }
        if current == nil,
           let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let window = ControlsWindow(windowScene: scene)
            window.isHidden = false
            current = window
        }
        current?.onMode = onMode
        current?.onKeyboard = onKeyboard
        current?.controller.layout = layout
        current?.controllerMode = controllerMode
    }

    /// The controller, while the window is up (for WineAutotest).
    static var controllerView: TouchControllerView? { current?.controller }

    static func setControllerMode(_ on: Bool) {
        current?.controllerMode = on
    }

    let controller = TouchControllerView()
    private let bar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let modeButton = UIButton(type: .system)
    private let keyboardButton = UIButton(type: .system)
    private var onMode: (Bool) -> Void = { _ in }
    private var onKeyboard: () -> Void = {}

    private var controllerMode = false {
        didSet { apply() }
    }

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .normal + 1
        backgroundColor = .clear

        let root = UIViewController()
        root.view = UIView()
        root.view.backgroundColor = .clear
        rootViewController = root

        controller.frame = root.view.bounds
        controller.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.view.addSubview(controller)

        for (button, symbol, action) in [(modeButton, "computermouse", #selector(toggleMode)),
                                         (keyboardButton, "keyboard", #selector(toggleKeyboard))] {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: symbol)
            configuration.baseForegroundColor = .white
            button.configuration = configuration
            button.addTarget(self, action: action, for: .touchUpInside)
        }
        keyboardButton.accessibilityLabel = "Keyboard"
        keyboardButton.accessibilityHint = "Shows or hides the on-screen keyboard"
        let stack = UIStackView(arrangedSubviews: [modeButton, keyboardButton])
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.contentView.addSubview(stack)
        bar.clipsToBounds = true
        bar.layer.cornerRadius = 20
        bar.alpha = 0.85
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(bar)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: bar.contentView.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: bar.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.contentView.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40),
            bar.centerXAnchor.constraint(equalTo: root.view.centerXAnchor),
            bar.topAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.topAnchor, constant: 6),
        ])
        apply()
    }

    required init?(coder: NSCoder) {
        fatalError("ControlsWindow is only created in code")
    }

    /// Never the key window: the keyboard and Winios.m (which looks for the key window to
    /// attach the game to) both belong to the app's own window.
    override var canBecomeKey: Bool { false }

    /// Touches that land on nothing of this window's go on to the app window below.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === rootViewController?.view ? nil : hit
    }

    private func apply() {
        controller.isHidden = !controllerMode
        if !controllerMode { controller.releaseAll() }
        modeButton.configuration?.image = UIImage(systemName: controllerMode ? "gamecontroller.fill" : "computermouse")
        modeButton.accessibilityLabel = controllerMode ? "Controller mode" : "Mouse mode"
        modeButton.accessibilityHint = "Switches between mouse mode and controller mode"
    }

    @objc private func toggleMode() {
        controllerMode.toggle()
        onMode(controllerMode)
    }

    @objc private func toggleKeyboard() {
        onKeyboard()
    }
}
