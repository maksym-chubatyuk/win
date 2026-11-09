import GameController
import QuartzCore
import UIKit

/// How the on-screen controller is laid out: its size and opacity, and where each group sits.
/// Kept for all programs, and for a program that has its own.
struct TouchLayout: Codable, Equatable {
    /// ABXY with RB/RT, the D-pad with LB/LT, and View/Menu.
    enum Group: String, Codable, CaseIterable { case face, dpad, system }

    struct Placement: Codable, Equatable {
        /// Moved from the default place by these fractions of the screen's width and height.
        var dx: Double = 0
        var dy: Double = 0
        var scale: Double = 1
    }

    var size: Double = 1
    var opacity: Double = 1
    var haptics = true
    var placements: [Group: Placement] = [:]

    subscript(group: Group) -> Placement {
        get { placements[group] ?? Placement() }
        set { placements[group] = newValue }
    }

    static let sizes = 0.6...1.5
    static let opacities = 0.3...2.0
    static let groupScales = 0.6...1.6

    private static func key(_ programID: String?) -> String { programID.map { "touchLayout.\($0)" } ?? "touchLayout" }

    private static func stored(_ programID: String?) -> TouchLayout? {
        UserDefaults.standard.data(forKey: key(programID)).flatMap { try? JSONDecoder().decode(TouchLayout.self, from: $0) }
    }

    /// A program's own layout, else the one for all programs.
    static func load(for programID: String?) -> TouchLayout {
        programID.flatMap(stored) ?? stored(nil) ?? TouchLayout()
    }

    static func hasOwn(_ programID: String) -> Bool { stored(programID) != nil }

    static func save(_ layout: TouchLayout, for programID: String?) {
        if let data = try? JSONEncoder().encode(layout) { UserDefaults.standard.set(data, forKey: key(programID)) }
    }

    static func removeOwn(_ programID: String) { UserDefaults.standard.removeObject(forKey: key(programID)) }
}

/// XInput's button bits (XINPUT_GAMEPAD_*), which Wine's xinput reports to the program.
struct PadButtons: OptionSet, Hashable {
    let rawValue: UInt16
    static let up = PadButtons(rawValue: 0x0001)
    static let down = PadButtons(rawValue: 0x0002)
    static let left = PadButtons(rawValue: 0x0004)
    static let right = PadButtons(rawValue: 0x0008)
    static let menu = PadButtons(rawValue: 0x0010)      // Start
    static let view = PadButtons(rawValue: 0x0020)      // Back
    static let leftThumb = PadButtons(rawValue: 0x0040)
    static let rightThumb = PadButtons(rawValue: 0x0080)
    static let leftShoulder = PadButtons(rawValue: 0x0100)
    static let rightShoulder = PadButtons(rawValue: 0x0200)
    static let a = PadButtons(rawValue: 0x1000)
    static let b = PadButtons(rawValue: 0x2000)
    static let x = PadButtons(rawValue: 0x4000)
    static let y = PadButtons(rawValue: 0x8000)
}

/// One controller's state, sticks from -1 to 1 with +y up, triggers from 0 to 1.
struct PadState: Equatable {
    var buttons: PadButtons = []
    var leftTrigger = 0.0, rightTrigger = 0.0
    var leftX = 0.0, leftY = 0.0, rightX = 0.0, rightY = 0.0
}

/// Player 1 as Windows programs see it through XInput: the on-screen controller and any
/// physical controller (Xbox, PlayStation, MFi) combined. Buttons from either count; a
/// stick or trigger takes whichever source is pushed further.
@MainActor
final class GamepadBridge {
    static let shared = GamepadBridge()

    /// The on-screen controller's state, and whether it is showing.
    var touch = PadState() { didSet { publish() } }
    var touchVisible = false { didSet { publish() } }

    private var started = false

    /// Player 1 stays connected for the whole program session, at rest when nothing is
    /// pressed. Games that look for controllers once at startup (every DirectInput game,
    /// and some XInput ones) otherwise found none unless the on-screen controller was
    /// already showing or a physical pad was paired at that moment, and never looked again.
    private var sessionReserved = false

    func start() {
        sessionReserved = true
        publish()
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.attachControllers() }
            }
        }
        attachControllers()
    }

    private func attachControllers() {
        for controller in GCController.controllers() {
            controller.handlerQueue = .main
            controller.extendedGamepad?.valueChangedHandler = { _, _ in
                MainActor.assumeIsolated { self.publish() }
            }
        }
        publish()
    }

    private var physical: PadState? {
        guard let pad = GCController.controllers().lazy.compactMap({ $0.extendedGamepad }).first else { return nil }
        var state = PadState()
        let map: [(GCControllerButtonInput?, PadButtons)] = [
            (pad.buttonA, .a), (pad.buttonB, .b), (pad.buttonX, .x), (pad.buttonY, .y),
            (pad.leftShoulder, .leftShoulder), (pad.rightShoulder, .rightShoulder),
            (pad.leftThumbstickButton, .leftThumb), (pad.rightThumbstickButton, .rightThumb),
            (pad.buttonMenu, .menu), (pad.buttonOptions, .view),
            (pad.dpad.up, .up), (pad.dpad.down, .down), (pad.dpad.left, .left), (pad.dpad.right, .right),
        ]
        for (button, bit) in map where button?.isPressed == true { state.buttons.insert(bit) }
        state.leftTrigger = Double(pad.leftTrigger.value)
        state.rightTrigger = Double(pad.rightTrigger.value)
        state.leftX = Double(pad.leftThumbstick.xAxis.value)
        state.leftY = Double(pad.leftThumbstick.yAxis.value)
        state.rightX = Double(pad.rightThumbstick.xAxis.value)
        state.rightY = Double(pad.rightThumbstick.yAxis.value)
        return state
    }

    func publish() {
        let hardware = physical
        guard touchVisible || hardware != nil || sessionReserved else {
            winios_gamepad_set_state(0, nil)
            return
        }
        var merged = hardware ?? PadState()
        if touchVisible {
            merged.buttons.formUnion(touch.buttons)
            merged.leftTrigger = max(merged.leftTrigger, touch.leftTrigger)
            merged.rightTrigger = max(merged.rightTrigger, touch.rightTrigger)
            if hypot(touch.leftX, touch.leftY) > hypot(merged.leftX, merged.leftY) {
                merged.leftX = touch.leftX; merged.leftY = touch.leftY
            }
            if hypot(touch.rightX, touch.rightY) > hypot(merged.rightX, merged.rightY) {
                merged.rightX = touch.rightX; merged.rightY = touch.rightY
            }
        }
        var state = winios_gamepad()
        state.connected = 1
        state.buttons = merged.buttons.rawValue
        state.left_trigger = Self.trigger(merged.leftTrigger)
        state.right_trigger = Self.trigger(merged.rightTrigger)
        state.lx = Self.axis(merged.leftX); state.ly = Self.axis(merged.leftY)
        state.rx = Self.axis(merged.rightX); state.ry = Self.axis(merged.rightY)
        winios_gamepad_set_state(0, &state)
    }

    private static func axis(_ value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        let v = min(max(value, -1), 1)
        return Int16((v * (v < 0 ? 32768 : 32767)).rounded())
    }

    private static func trigger(_ value: Double) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8((min(max(value, 0), 1) * 255).rounded())
    }
}

/// An Xbox-style controller over the program, in landscape. While it is showing, the
/// screen is a controller and not a mouse: every touch goes to it.
///
///                       [View] [ui] [Menu]
///
///      left half: left stick                right half: right stick
///      (starts where the thumb lands)
///              LT                                       RT
///         LB                                                 RB
///                                                              Y
///       ▢                                                    X   B
///     ▢   ▢                                                    A
///       ▢
///
/// LB/LT are ring segments wrapped around the D-pad, centred on the 15° and 50° lines out from
/// its centre; RB/RT the same (mirrored) around ABXY.
///
/// The sticks are never drawn and give no feedback: a thumb landing anywhere on the left
/// half becomes the left stick centred on that spot, and the right half the right stick. ABXY
/// and the D-pad are bare outlines in the bottom corners, with the bumpers and triggers as
/// faint labels around them. Double-tap a stick and keep holding for L3/R3.
final class TouchControllerView: UIView {
    private enum Control: Hashable {
        case button(PadButtons)
        case leftTrigger, rightTrigger
        case leftStick, rightStick
    }

    private struct Pad {
        let control: Control
        let label: String
        var center = CGPoint.zero
        var size = CGSize.zero
        var round = true
        let view = UILabel()
        /// Bumpers and triggers: a segment of a ring around their cluster, drawn by `shape`.
        var arc: Arc?
        let shape = CAShapeLayer()
    }

    /// A ring segment: radii from `center`, and its middle angle and half width in radians
    /// (UIKit angles, clockwise from +x since y points down).
    private struct Arc {
        var center: CGPoint
        var inner: CGFloat, outer: CGFloat
        var mid: CGFloat, half: CGFloat

        var path: CGPath {
            let path = UIBezierPath(arcCenter: center, radius: outer, startAngle: mid - half, endAngle: mid + half, clockwise: true)
            path.addArc(withCenter: center, radius: inner, startAngle: mid + half, endAngle: mid - half, clockwise: false)
            path.close()
            return path.cgPath
        }

        var labelCenter: CGPoint {
            let r = (inner + outer) / 2
            return CGPoint(x: center.x + cos(mid) * r, y: center.y + sin(mid) * r)
        }

        /// With a margin around it, as thumbs land imprecisely.
        func contains(_ point: CGPoint, margin: CGFloat) -> Bool {
            let dx = point.x - center.x, dy = point.y - center.y
            let r = hypot(dx, dy)
            guard r >= inner - margin, r <= outer + margin else { return false }
            var delta = atan2(dy, dx) - mid
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            return abs(delta) <= half + margin / max(r, 1)
        }
    }

    private var pads: [Pad] = []
    /// Where each held stick's thumb is now, kept within stickRadius of its origin.
    private var stickPositions: [Control: CGPoint] = [:]
    private var stickRadius: CGFloat = 56

    /// Which control each finger holds, and where a stick's finger started.
    private var holds: [AnyHashable: Control] = [:]
    private var stickOrigins: [Control: CGPoint] = [:]
    private var lastStickRelease: [Control: (time: TimeInterval, at: CGPoint)] = [:]
    private var clicked: Set<Control> = []

    private let haptics = UIImpactFeedbackGenerator(style: .light)
    private static let deadZone = 0.12

    var layout = TouchLayout() {
        didSet {
            guard layout != oldValue else { return }
            setNeedsLayout()
            resetAlpha()
        }
    }

    /// Editing the layout: a finger drags a group and two pinch it, instead of playing.
    var isEditing = false {
        didSet {
            guard isEditing != oldValue else { return }
            releaseAll()
            pinch.isEnabled = isEditing
            outlines.values.forEach { $0.isHidden = !isEditing }
            setNeedsLayout()
        }
    }

    /// Called while editing, with the changed layout.
    var onLayoutChange: ((TouchLayout) -> Void)?

    private var outlines: [TouchLayout.Group: CAShapeLayer] = [:]
    private var drags: [ObjectIdentifier: (group: TouchLayout.Group, start: CGPoint, placement: TouchLayout.Placement)] = [:]
    private var pinched: (group: TouchLayout.Group, scale: Double)?
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        let buttons: [(Control, String)] = [
            (.button(.a), "A"), (.button(.b), "B"), (.button(.x), "X"), (.button(.y), "Y"),
            (.button(.up), "▲"), (.button(.down), "▼"), (.button(.left), "◀"), (.button(.right), "▶"),
            (.button(.leftShoulder), "LB"), (.button(.rightShoulder), "RB"),
            (.leftTrigger, "LT"), (.rightTrigger, "RT"),
            (.button(.view), "⧉"), (.button(.menu), "≡"),
        ]
        for (control, label) in buttons {
            var pad = Pad(control: control, label: label)
            // ABXY and the D-pad are bare outlines, placed where a controller has them;
            // the bumpers, triggers and View/Menu keep a small faint label.
            let kind = Self.kind(of: control)
            pad.view.text = kind == .face || kind == .dpad ? nil : label
            pad.view.textAlignment = .center
            pad.view.textColor = .white
            pad.view.adjustsFontSizeToFitWidth = true
            pad.view.minimumScaleFactor = 0.6
            pad.view.layer.borderColor = UIColor.white.cgColor
            pad.view.layer.borderWidth = kind == .shoulder ? 0 : 2
            pad.view.backgroundColor = .clear
            pad.view.clipsToBounds = true
            pad.view.alpha = Self.idleAlpha(of: kind) // layout.opacity applies in resetAlpha
            pad.view.isAccessibilityElement = true
            pad.view.accessibilityLabel = Self.accessibilityName(of: control, label: label)
            if kind == .shoulder {
                pad.shape.strokeColor = UIColor.white.cgColor
                pad.shape.fillColor = UIColor.clear.cgColor
                pad.shape.lineWidth = 1.5
                pad.shape.lineJoin = .round
                pad.shape.opacity = Float(Self.idleAlpha(of: kind))
                layer.addSublayer(pad.shape)
            }
            addSubview(pad.view)
            pads.append(pad)
        }
        for group in TouchLayout.Group.allCases {
            let outline = CAShapeLayer()
            outline.strokeColor = UIColor.systemYellow.cgColor
            outline.fillColor = UIColor.systemYellow.withAlphaComponent(0.08).cgColor
            outline.lineWidth = 1.5
            outline.lineDashPattern = [6, 4]
            outline.isHidden = true
            layer.addSublayer(outline)
            outlines[group] = outline
        }
        pinch.isEnabled = false
        addGestureRecognizer(pinch)
    }

    required init?(coder: NSCoder) {
        fatalError("TouchControllerView is only created in code")
    }

    private static func accessibilityName(of control: Control, label: String) -> String {
        switch control {
        case .button(.up): "D-pad up"
        case .button(.down): "D-pad down"
        case .button(.left): "D-pad left"
        case .button(.right): "D-pad right"
        case .button(.view): "View"
        case .button(.menu): "Menu"
        default: label
        }
    }

    private static func group(of control: Control) -> TouchLayout.Group? {
        switch kind(of: control) {
        case .face: .face
        case .dpad: .dpad
        case .shoulder: control == .rightTrigger || control == .button(.rightShoulder) ? .face : .dpad
        case .system: control == .leftStick || control == .rightStick ? nil : .system
        }
    }

    private func idleAlpha(of control: Control) -> CGFloat {
        min(1, max(0.05, Self.idleAlpha(of: Self.kind(of: control)) * CGFloat(layout.opacity)))
    }

    private func resetAlpha() {
        for pad in pads {
            pad.view.alpha = idleAlpha(of: pad.control)
            pad.shape.opacity = Float(idleAlpha(of: pad.control))
        }
    }

    private enum Kind { case face, dpad, shoulder, system }

    private static func kind(of control: Control) -> Kind {
        switch control {
        case .button(.a), .button(.b), .button(.x), .button(.y): .face
        case .button(.up), .button(.down), .button(.left), .button(.right): .dpad
        case .leftTrigger, .rightTrigger, .button(.leftShoulder), .button(.rightShoulder): .shoulder
        default: .system
        }
    }

    private static func idleAlpha(of kind: Kind) -> CGFloat {
        switch kind {
        case .face, .dpad: 0.45
        case .shoulder: 0.28
        case .system: 0.4
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The phone's own edges, not the safe area: in landscape that leaves about 60
        // points unused on each side, the black bars beside a 16:9 program. The corners are
        // rounded (about 55 points), which the offsets below keep clear of.
        let area = bounds.insetBy(dx: 8, dy: 6)
        guard area.width > 0, area.height > 0 else { return }
        // Sized for a 6.9-inch phone in landscape (about 400 points of usable height);
        // smaller screens scale down so nothing overlaps.
        let base: CGFloat = min(1.1, max(0.7, min(area.height, area.width / 2) / 420)) * CGFloat(layout.size)
        // Each group's own size and place (TouchLayout), on top of the screen's.
        func scale(_ group: TouchLayout.Group) -> CGFloat { base * CGFloat(layout[group].scale) }
        func offset(_ group: TouchLayout.Group) -> CGPoint {
            CGPoint(x: CGFloat(layout[group].dx) * bounds.width, y: CGFloat(layout[group].dy) * bounds.height)
        }
        let fs = scale(.face), ds = scale(.dpad), ss = scale(.system)
        let face = 27.6 * fs, faceGap = 51.6 * fs, arm = 54.4 * ds, dpadKey = 48 * ds
        stickRadius = 56 * base

        // Offsets from each bottom corner; the left side mirrors the right.
        let faceCenter = CGPoint(x: area.maxX - 84 * fs + offset(.face).x, y: area.maxY - 84 * fs + offset(.face).y)
        let dpad = CGPoint(x: area.minX + 84 * ds + offset(.dpad).x, y: area.maxY - 84 * ds + offset(.dpad).y)
        let top = CGPoint(x: area.midX + offset(.system).x, y: area.minY + 20 * ss + offset(.system).y)

        // Bumpers and triggers wrap around their cluster as ring segments, centred on the 15°
        // (LB/RB) and 50° (LT/RT) lines from its centre, towards the middle of the screen.
        func ring(_ center: CGPoint, degrees: CGFloat, towardsLeft: Bool, scale s: CGFloat) -> Arc {
            let up = degrees * .pi / 180
            return Arc(center: center, inner: 90 * s, outer: 124 * s,
                       mid: towardsLeft ? up - .pi : -up, half: 16 * .pi / 180)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for index in pads.indices {
            var pad = pads[index]
            switch pad.control {
            case .button(.a): pad.center = CGPoint(x: faceCenter.x, y: faceCenter.y + faceGap)
            case .button(.b): pad.center = CGPoint(x: faceCenter.x + faceGap, y: faceCenter.y)
            case .button(.x): pad.center = CGPoint(x: faceCenter.x - faceGap, y: faceCenter.y)
            case .button(.y): pad.center = CGPoint(x: faceCenter.x, y: faceCenter.y - faceGap)
            case .button(.up): pad.center = CGPoint(x: dpad.x, y: dpad.y - arm)
            case .button(.down): pad.center = CGPoint(x: dpad.x, y: dpad.y + arm)
            case .button(.left): pad.center = CGPoint(x: dpad.x - arm, y: dpad.y)
            case .button(.right): pad.center = CGPoint(x: dpad.x + arm, y: dpad.y)
            // Triggers on the steeper line, above the bumpers as on a controller.
            case .rightTrigger: pad.arc = ring(faceCenter, degrees: 50, towardsLeft: true, scale: fs)
            case .button(.rightShoulder): pad.arc = ring(faceCenter, degrees: 15, towardsLeft: true, scale: fs)
            case .leftTrigger: pad.arc = ring(dpad, degrees: 50, towardsLeft: false, scale: ds)
            case .button(.leftShoulder): pad.arc = ring(dpad, degrees: 15, towardsLeft: false, scale: ds)
            // Top centre, either side of the mode and keyboard buttons.
            case .button(.view): pad.center = CGPoint(x: top.x - 100 * ss, y: top.y)
            case .button(.menu): pad.center = CGPoint(x: top.x + 100 * ss, y: top.y)
            default: break
            }
            let s: CGFloat = Self.group(of: pad.control).map { scale($0) } ?? base
            switch pad.control {
            case .button(.up), .button(.down), .button(.left), .button(.right):
                pad.size = CGSize(width: dpadKey, height: dpadKey); pad.round = false
            case .leftTrigger, .rightTrigger, .button(.leftShoulder), .button(.rightShoulder):
                // The label only; the drawn shape is the ring segment.
                pad.size = CGSize(width: 34 * s, height: 22 * s)
            case .button(.view), .button(.menu):
                pad.size = CGSize(width: 56 * s, height: 26 * s)
            default:
                pad.size = CGSize(width: face * 2, height: face * 2)
            }
            if let arc = pad.arc {
                pad.center = arc.labelCenter
                pad.shape.frame = bounds
                pad.shape.path = arc.path
            }
            pad.view.frame = CGRect(x: pad.center.x - pad.size.width / 2, y: pad.center.y - pad.size.height / 2,
                                    width: pad.size.width, height: pad.size.height)
            pad.view.layer.cornerRadius = pad.round ? pad.size.height / 2 : 9 * s
            pad.view.font = .systemFont(ofSize: 15 * s, weight: .semibold)
            pads[index] = pad
        }

        // While editing: each group's outline.
        if isEditing {
            for group in TouchLayout.Group.allCases {
                outlines[group]?.frame = bounds
                outlines[group]?.path = UIBezierPath(roundedRect: frame(of: group).insetBy(dx: -6, dy: -6), cornerRadius: 10).cgPath
                outlines[group]?.lineWidth = pinched?.group == group || drags.values.contains { $0.group == group } ? 2.5 : 1.5
            }
        }
    }

    /// The area a group covers, its ring segments included.
    private func frame(of group: TouchLayout.Group) -> CGRect {
        pads.filter { Self.group(of: $0.control) == group }
            .map { $0.arc.map { UIBezierPath(cgPath: $0.path).bounds } ?? $0.view.frame }
            .reduce(CGRect.null) { $0.union($1) }
    }

    private func group(at point: CGPoint) -> TouchLayout.Group? {
        TouchLayout.Group.allCases.first { frame(of: $0).insetBy(dx: -16, dy: -16).contains(point) }
    }

    // MARK: Editing

    private func editBegan(_ finger: ObjectIdentifier, at point: CGPoint) {
        guard let group = group(at: point) else { return }
        drags[finger] = (group, point, layout[group])
        setNeedsLayout()
    }

    private func editMoved(_ finger: ObjectIdentifier, to point: CGPoint) {
        guard let drag = drags[finger], bounds.width > 0, bounds.height > 0 else { return }
        var placement = drag.placement
        placement.dx = min(0.6, max(-0.6, placement.dx + Double((point.x - drag.start.x) / bounds.width)))
        placement.dy = min(0.6, max(-0.6, placement.dy + Double((point.y - drag.start.y) / bounds.height)))
        layout[drag.group] = placement
        onLayoutChange?(layout)
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            // A pinch is two fingers: no drag meanwhile.
            drags.removeAll()
            if let group = group(at: gesture.location(in: self)) { pinched = (group, layout[group].scale) }
        case .changed:
            guard let pinched else { return }
            layout[pinched.group].scale = min(TouchLayout.groupScales.upperBound,
                                              max(TouchLayout.groupScales.lowerBound, pinched.scale * Double(gesture.scale)))
            onLayoutChange?(layout)
        default:
            pinched = nil
            setNeedsLayout()
        }
    }

    // MARK: Touches

    /// A slightly larger target than drawn, as thumbs land imprecisely. Anywhere else is
    /// the stick for that half of the screen.
    private func control(at point: CGPoint) -> Control {
        for pad in pads {
            if let arc = pad.arc {
                if arc.contains(point, margin: 8) { return pad.control }
                continue
            }
            let target = CGRect(origin: .zero, size: pad.size).insetBy(dx: -8, dy: -8)
                .offsetBy(dx: pad.center.x - pad.size.width / 2, dy: pad.center.y - pad.size.height / 2)
            if target.contains(point) { return pad.control }
        }
        return point.x < bounds.midX ? .leftStick : .rightStick
    }

    // A finger is keyed by its UITouch; WineAutotest's simulated fingers use their own keys.

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isEditing {
            for touch in touches where pinched == nil { editBegan(ObjectIdentifier(touch), at: touch.location(in: self)) }
            return
        }
        for touch in touches { fingerDown(ObjectIdentifier(touch), at: touch.location(in: self), time: touch.timestamp) }
        update()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isEditing {
            for touch in touches { editMoved(ObjectIdentifier(touch), to: touch.location(in: self)) }
            return
        }
        for touch in touches { fingerMoved(ObjectIdentifier(touch), to: touch.location(in: self)) }
        update()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isEditing {
            for touch in touches { drags[ObjectIdentifier(touch)] = nil }
            setNeedsLayout()
            return
        }
        for touch in touches { fingerUp(ObjectIdentifier(touch), at: touch.location(in: self), time: touch.timestamp) }
        update()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func fingerDown(_ finger: AnyHashable, at point: CGPoint, time: TimeInterval) {
        let control = control(at: point)
        guard !holds.values.contains(control) else { return }
        holds[finger] = control
        switch control {
        case .leftStick, .rightStick:
            // Floating: the stick's centre is where the thumb landed, so no first push is
            // lost to travel.
            stickOrigins[control] = point
            if let last = lastStickRelease[control], time - last.time < 0.3,
               hypot(point.x - last.at.x, point.y - last.at.y) < stickRadius * 1.5 {
                clicked.insert(control)
            }
            stickPositions[control] = point
        default:
            if layout.haptics { haptics.impactOccurred() }
        }
        setActive(control, true)
    }

    private func fingerMoved(_ finger: AnyHashable, to point: CGPoint) {
        guard let control = holds[finger], let origin = stickOrigins[control] else { return }
        var dx = point.x - origin.x, dy = point.y - origin.y
        let length = hypot(dx, dy)
        if length > stickRadius { dx *= stickRadius / length; dy *= stickRadius / length }
        stickPositions[control] = CGPoint(x: origin.x + dx, y: origin.y + dy)
    }

    private func fingerUp(_ finger: AnyHashable, at point: CGPoint, time: TimeInterval) {
        guard let control = holds.removeValue(forKey: finger) else { return }
        if control == .leftStick || control == .rightStick {
            lastStickRelease[control] = (time, point)
            stickOrigins[control] = nil
            stickPositions[control] = nil
            clicked.remove(control)
        }
        setActive(control, false)
    }

    /// For WineAutotest: a finger put down, moved or lifted at a point given as a fraction
    /// of the view (0...1 across and down), through the same code as a real touch.
    func simulate(finger: String, phase: UITouch.Phase, x: CGFloat, y: CGFloat) {
        let point = CGPoint(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height)
        let time = ProcessInfo.processInfo.systemUptime
        switch phase {
        case .began: fingerDown(finger, at: point, time: time)
        case .moved: fingerMoved(finger, to: point)
        default: fingerUp(finger, at: point, time: time)
        }
        update()
    }

    /// Where a button is drawn, as a fraction of the view, for WineAutotest.
    func fraction(ofButton label: String) -> CGPoint? {
        guard let pad = pads.first(where: { $0.label == label }), bounds.width > 0 else { return nil }
        return CGPoint(x: (pad.center.x - bounds.minX) / bounds.width, y: (pad.center.y - bounds.minY) / bounds.height)
    }

    /// Lets go of everything, for when the controller is hidden mid-press.
    func releaseAll() {
        for control in Set(holds.values) { setActive(control, false) }
        holds.removeAll()
        stickOrigins.removeAll()
        stickPositions.removeAll()
        clicked.removeAll()
        update()
    }

    private func setActive(_ control: Control, _ active: Bool) {
        switch control {
        // The sticks are never drawn.
        case .leftStick, .rightStick: break
        default:
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            for pad in pads where pad.control == control {
                let alpha = active ? max(0.9, idleAlpha(of: control)) : idleAlpha(of: control)
                pad.view.alpha = alpha
                if pad.arc != nil {
                    pad.shape.opacity = Float(alpha)
                    pad.shape.fillColor = active ? UIColor.white.withAlphaComponent(0.3).cgColor : UIColor.clear.cgColor
                } else {
                    pad.view.backgroundColor = active ? UIColor.white.withAlphaComponent(0.3) : .clear
                }
            }
        }
    }

    /// The pad state from what each finger holds. Not while editing: the editor's
    /// controller is only a picture.
    private func update() {
        guard !isEditing else { return }
        var state = PadState()
        for control in holds.values {
            switch control {
            case .button(let bit): state.buttons.insert(bit)
            case .leftTrigger: state.leftTrigger = 1
            case .rightTrigger: state.rightTrigger = 1
            case .leftStick, .rightStick:
                let origin = stickOrigins[control] ?? .zero
                let knob = stickPositions[control] ?? origin
                let (x, y) = Self.shaped(dx: (knob.x - origin.x) / stickRadius, dy: (origin.y - knob.y) / stickRadius)
                if control == .leftStick {
                    state.leftX = x; state.leftY = y
                    if clicked.contains(control) { state.buttons.insert(.leftThumb) }
                } else {
                    state.rightX = x; state.rightY = y
                    if clicked.contains(control) { state.buttons.insert(.rightThumb) }
                }
            }
        }
        GamepadBridge.shared.touch = state
    }

    /// A radial dead zone, so a resting thumb does not drift, with the rest of the
    /// travel rescaled to the full range.
    private static func shaped(dx: Double, dy: Double) -> (Double, Double) {
        let length = hypot(dx, dy)
        guard length > deadZone else { return (0, 0) }
        let scaled = min(1, (length - deadZone) / (1 - deadZone))
        return (dx / length * scaled, dy / length * scaled)
    }
}
