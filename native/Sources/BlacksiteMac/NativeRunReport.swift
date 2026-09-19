import AppKit
import BlacksiteCore

enum NativeRunOutcome: String, Sendable {
    case success, failure, aborted
    var title: String {
        switch self {
        case .success: return "MISSION ERFÜLLT"
        case .failure: return "EINSATZ GESCHEITERT"
        case .aborted: return "EINSATZ ABGEBROCHEN"
        }
    }
}

/// A value snapshot taken after the final event batch; inventory refills and
/// subsequent menu changes cannot rewrite the finished operation.
@MainActor
struct NativeRunReport: Sendable {
    let configuration: ActiveRunConfiguration
    let outcome: NativeRunOutcome
    let elapsed: Double
    let statistics: RunStatistics
    let mapName: String
    let variantTitle: String
    let extraction: String

    init(configuration: ActiveRunConfiguration, simulation: CombatSimulation, outcome: NativeRunOutcome) {
        self.configuration = configuration; self.outcome = outcome
        elapsed = simulation.elapsed; statistics = simulation.runStatistics
        mapName = simulation.map.displayName
        let base = PublishedMapRegistry.map(id: configuration.mapID) ?? simulation.map
        variantTitle = (try? RunVariantCatalog.resolve(map: base, seed: configuration.seed).title) ?? "Standard"
        if outcome != .success { extraction = "Keine Extraktion abgeschlossen" }
        else if simulation.missionKind == .secureRadio { extraction = "Funkstation vor Ort gesichert" }
        else if let id = simulation.selectedExtractionID,
                let exit = simulation.operationStatus?.extractions.first(where: { $0.id == id }) {
            extraction = exit.title
        } else { extraction = NativeMissionPresentation.extractionTitle(simulation.map) }
    }

    var timeText: String { String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60) }
    var setupText: String {
        let difficulty = configuration.difficulty == .easy ? "Rekrut" : configuration.difficulty == .normal ? "Operator" : "Veteran"
        return "\(NativeMissionPresentation.name(configuration.mission)) · \(difficulty) · \(NativeClassPresentation.name(configuration.loadout.operatorClass)) · \(NativeCamouflagePresentation.name(configuration.loadout.camouflage))"
    }
    var rows: [String] {
        let s = statistics
        return [
            "\(timeText) Einsatzzeit · \(s.kills) Gegner ausgeschaltet · \(s.radioReports) Funkmeldungen · \(s.shouts) Rufe",
            "Vorbereitung: \(s.disabledGeneratorIDs.count) Generatoren abgeschaltet · \(s.openedGateIDs.count) Tore geöffnet · \(s.maintenanceSwitches) Schalter betätigt",
            "\(s.destroyedDeviceIDs.count) Geräte zerstört · \(extraction)",
            "Verbrauch: \(s.rifleShots) AR-4-Schuss · \(s.sniperShots) M82-Schuss · \(s.fragmentationGrenadesThrown) Splittergranaten",
            "\(s.smokeGrenadesThrown) Rauchgranaten · \(s.decoysThrown) Köder · \(s.breachChargesPlaced) Durchbruchladungen · \(s.reconMarks) Markierungen"
        ]
    }
    var accessibilityText: String {
        ([outcome.title, mapName + " · " + variantTitle, setupText] + rows +
         ["Version \(configuration.mapVersion) · Seed \(configuration.seed)",
          "Erneut antreten startet dieselbe Lage mit vollem Startvorrat."]).joined(separator: ". ")
    }
}

@MainActor
final class NativeRunReportView: NSView {
    private(set) var report: NativeRunReport?
    private let title = NSTextField(labelWithString: "")
    private let location = NSTextField(wrappingLabelWithString: "")
    private let setup = NSTextField(wrappingLabelWithString: "")
    private let details = NSTextField(wrappingLabelWithString: "")
    private let identity = NSTextField(wrappingLabelWithString: "")
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 28, weight: .heavy)
        location.font = .systemFont(ofSize: 15, weight: .semibold)
        setup.font = .systemFont(ofSize: 12)
        details.font = .systemFont(ofSize: 13)
        identity.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        identity.textColor = .secondaryLabelColor
        for field in [title, location, setup, details, identity] { addSubview(field) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("Lokaler Einsatzbericht")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ report: NativeRunReport?) {
        self.report = report
        guard let report else { return }
        title.stringValue = report.outcome.title
        location.stringValue = report.mapName + " · " + report.variantTitle
        setup.stringValue = report.setupText
        details.stringValue = report.rows.joined(separator: "\n\n")
        identity.stringValue = "Version \(report.configuration.mapVersion) · Seed \(report.configuration.seed)\nErneut antreten: gleiche Lage und Ausrüstung, voller Startvorrat."
        setAccessibilityValue(report.accessibilityText)
    }
    override func layout() {
        super.layout()
        let width = bounds.width
        title.frame = NSRect(x: 0, y: 0, width: width, height: 36)
        location.frame = NSRect(x: 0, y: 46, width: width, height: 25)
        setup.frame = NSRect(x: 0, y: 78, width: width, height: 35)
        details.frame = NSRect(x: 0, y: 124, width: width, height: 174)
        identity.frame = NSRect(x: 0, y: 311, width: width, height: 38)
    }
}
