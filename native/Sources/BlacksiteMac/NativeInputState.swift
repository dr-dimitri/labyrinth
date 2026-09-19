/// Pure physical-input state. The coordinator performs discrete commands from
/// press/pulse results and forwards the snapshot to the fixed-step simulation.
struct NativeInputFrame: Equatable, Sendable {
    let moveForward: Float
    let moveRight: Float
    let yawAxis: Float
    let pitchAxis: Float
    let fire: Bool
    let aim: Bool
    let sprint: Bool
    let interact: Bool
}

struct NativeInputState: Sendable {
    private(set) var bindings: NativeBindings
    private(set) var aimMode: NativeActionMode
    private(set) var sprintMode: NativeActionMode
    private var down = Set<NativeInputButton>()
    private var pendingFire = false
    private var aimLatched = false
    private var sprintLatched = false

    init(bindings: NativeBindings = .defaults, aimMode: NativeActionMode = .hold, sprintMode: NativeActionMode = .hold) {
        self.bindings = bindings; self.aimMode = aimMode; self.sprintMode = sprintMode
        down.reserveCapacity(24)
    }

    @discardableResult mutating func press(_ button: NativeInputButton, isRepeat: Bool = false) -> [NativeInputAction] {
        guard !isRepeat else { return [] }
        if case .wheel(let direction) = button { return pulse(direction) }
        guard let owner = bindings.owner(of: button), down.insert(button).inserted else { return [] }
        began(owner.action)
        return [owner.action]
    }

    mutating func release(_ button: NativeInputButton) { down.remove(button) }

    /// Wheel events never create a held button, even when bound to fire.
    @discardableResult mutating func pulse(_ direction: NativeWheelDirection) -> [NativeInputAction] {
        guard let owner = bindings.owner(of: .wheel(direction)) else { return [] }
        began(owner.action)
        return [owner.action]
    }

    func snapshot() -> NativeInputFrame {
        func axis(_ positive: NativeInputAction, _ negative: NativeInputAction) -> Float {
            (held(positive) ? 1 : 0) - (held(negative) ? 1 : 0)
        }
        return NativeInputFrame(moveForward: axis(.moveForward,.moveBackward), moveRight: axis(.moveRight,.moveLeft),
                                yawAxis: axis(.lookLeft,.lookRight), pitchAxis: axis(.lookUp,.lookDown),
                                fire: pendingFire || held(.fire), aim: aimMode == .toggle ? aimLatched : held(.aim),
                                sprint: sprintMode == .toggle ? sprintLatched : held(.sprint), interact: held(.interact))
    }

    /// Call only after simulation.elapsed advances, never just because a
    /// display frame was drawn. This preserves taps shorter than one fixed step.
    mutating func didAdvanceSimulation() { pendingFire = false }

    mutating func reconfigure(bindings: NativeBindings, aimMode: NativeActionMode, sprintMode: NativeActionMode) {
        self.bindings = bindings; self.aimMode = aimMode; self.sprintMode = sprintMode
        clear()
    }

    /// Pause, focus loss, restart and binding changes clear held inputs, pending
    /// fire and toggles together. Late releases and key repeats cannot relatch.
    mutating func clear() {
        down.removeAll(keepingCapacity: true)
        pendingFire = false; aimLatched = false; sprintLatched = false
    }

    private func held(_ action: NativeInputAction) -> Bool {
        if let primary = bindings.button(for: action, slot: .primary), down.contains(primary) { return true }
        if let secondary = bindings.button(for: action, slot: .secondary), down.contains(secondary) { return true }
        return false
    }

    private mutating func began(_ action: NativeInputAction) {
        if action == .fire { pendingFire = true }
        if action == .aim && aimMode == .toggle { aimLatched.toggle() }
        if action == .sprint && sprintMode == .toggle { sprintLatched.toggle() }
    }
}
