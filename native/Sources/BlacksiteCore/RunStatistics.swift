/// Actions completed during this run. Inventory refills and presentation event
/// draining never change these counters; initial map conditions are not actions.
public struct RunStatistics: Equatable, Sendable {
    public private(set) var rifleShots = 0
    public private(set) var sniperShots = 0
    public private(set) var fragmentationGrenadesThrown = 0
    public private(set) var smokeGrenadesThrown = 0
    public private(set) var decoysThrown = 0
    public private(set) var breachChargesPlaced = 0
    public private(set) var reconMarks = 0
    public private(set) var radioReports = 0
    public private(set) var shouts = 0
    public private(set) var deviceActivations = 0
    public private(set) var maintenanceSwitches = 0
    public private(set) var kills = 0
    public private(set) var headshotKills = 0
    public private(set) var disabledGeneratorIDs: [Int] = []
    public private(set) var openedGateIDs: [Int] = []
    public private(set) var destroyedDeviceIDs: [Int] = []
    public private(set) var completedObjectiveIDs: [String] = []
    /// Entering an exit selects it; the run result determines whether it was used.
    public private(set) var selectedExtractionID: String?

    public init() {}

    mutating func record(_ event: GameEvent, map: MapDefinition) {
        switch event.kind {
        case .shot:
            switch event.weapon {
            case .rifle: rifleShots += 1
            case .sniper: sniperShots += 1
            case nil: break
            }
        case .throwGrenade: fragmentationGrenadesThrown += 1
        case .throwSmoke: smokeGrenadesThrown += 1
        case .decoyThrown: decoysThrown += 1
        case .breachChargePlaced: breachChargesPlaced += 1
        case .reconMarked: reconMarks += 1
        case .contactReportTransmitted:
            switch event.contactReport?.channel {
            case .radio: radioReports += 1
            case .localShout: shouts += 1
            case nil: break
            }
        case .deviceActivated:
            deviceActivations += 1
            guard let device = event.device else { return }
            if device.kind == .generator, !device.enabled {
                appendUnique(device.id, to: &disabledGeneratorIDs)
            } else if device.kind == .maintenanceSwitch {
                maintenanceSwitches += 1
            }
        case .gateStopped:
            guard let device = event.device, !device.isMoving else { return }
            if device.kind == .serviceGate, device.gateProgress == 1 {
                appendUnique(device.id, to: &openedGateIDs)
            } else if device.kind == .maintenanceSwitch, !device.destroyed,
                      device.gateProgress == (device.enabled ? 1 : 0),
                      let definition = map.environment.devices.first(where: { $0.id == device.id }),
                      definition.linkedGateIDs.count == 2 {
                // Coupled gates emit one completion from their controller.
                let openGate = definition.linkedGateIDs[device.enabled ? 0 : 1]
                appendUnique(openGate, to: &openedGateIDs)
            }
        case .deviceDestroyed:
            appendUnique(event.id, to: &destroyedDeviceIDs)
            guard let device = event.device, device.destroyed else { return }
            if device.kind == .generator, !device.enabled {
                appendUnique(device.id, to: &disabledGeneratorIDs)
            } else if device.kind == .serviceGate, device.gateProgress == 1 {
                appendUnique(device.id, to: &openedGateIDs)
            }
        case .operationObjectiveCompleted:
            if let objective = event.operationObjective, objective.completed {
                appendUnique(objective.id, to: &completedObjectiveIDs)
            }
        case .extractionSelected:
            if let id = event.extractionID { selectedExtractionID = id }
        case .kill:
            kills += 1
            if event.headshot { headshotKills += 1 }
        default: break
        }
    }
}

/// IDs are bounded by the authored map and retained in first-action order.
private func appendUnique<ID: Equatable>(_ id: ID, to values: inout [ID]) {
    if !values.contains(id) { values.append(id) }
}
