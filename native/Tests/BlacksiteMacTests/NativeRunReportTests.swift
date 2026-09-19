import AppKit
import Testing
@testable import BlacksiteCore
@testable import BlacksiteMac

@MainActor
@Suite(.serialized)
struct NativeRunReportTests {
    @Test func reproducibleDiagnosticsRejectInvalidSeeds() throws {
        #expect(try NativeRunSeed.from(arguments: []) == 1745)
        #expect(try NativeRunSeed.from(arguments: ["--seed", String(UInt64.max)]) == UInt64.max)
        for value in ["-1", "18446744073709551616", "text"] {
            #expect(throws: (any Error).self) { try NativeRunSeed.from(arguments: ["--seed", value]) }
        }
        #expect(throws: (any Error).self) { try NativeRunSeed.from(arguments: ["--seed"]) }
    }
    @Test func reportFreezesActualConsumptionAndRetryResetsIt() throws {
        let run = ActiveRunConfiguration(map: .sirocco, seed: UInt64.max, mission: .operation,
                                         difficulty: .normal, loadout: .init())
        let game = try run.makeSimulation()
        #expect(game.throwGrenade())
        #expect(game.throwSmokeGrenade())
        var fire = GameInput(); fire.fire = true
        game.step(deltaTime: 1.0 / 120, input: fire)
        game.drainEvents()
        let report = NativeRunReport(configuration: run, simulation: game, outcome: .aborted)
        #expect(report.statistics.fragmentationGrenadesThrown == 1)
        #expect(report.statistics.smokeGrenadesThrown == 1 && report.statistics.rifleShots == 1)
        #expect(report.configuration.seed == UInt64.max)
        #expect(report.extraction == "Keine Extraktion abgeschlossen")
        game.damagePlayer(amount: 1000, from: .zero)
        let failed = NativeRunReport(configuration: run, simulation: game, outcome: .failure)
        #expect(game.state == .lost && failed.outcome == .failure && report.outcome == .aborted)
        let retry = try run.makeSimulation()
        #expect(retry.runStatistics == RunStatistics() && retry.elapsed == 0)
        #expect(report.statistics.fragmentationGrenadesThrown == 1)
        #expect(retry.map.dataSite == game.map.dataSite)
        #expect(retry.map.obstacles.map(\.destroyed) == game.map.obstacles.map(\.destroyed))
    }

    @Test func newSeedChangesAuthoredVariantAndKeepsFullWidth() throws {
        for previous in [UInt64(0), 1, 2, UInt64.max] {
            let next = NativeRunSeed.next(after: previous, candidate: previous)
            #expect(next != previous && next % 3 != previous % 3)
            #expect(try RunVariantCatalog.resolve(map: .kessel9, seed: previous).id != RunVariantCatalog.resolve(map: .kessel9, seed: next).id)
        }
        #expect(NativeRunSeed.next(after: nil, candidate: UInt64.max) == UInt64.max)
    }

    @Test func allOutcomesAndLongIdentityRemainReadableAtMinimumSize() throws {
        for map in PublishedMapRegistry.maps {
            for outcome in [NativeRunOutcome.success, .failure, .aborted] {
                let config = ActiveRunConfiguration(map: map, seed: UInt64.max, mission: .operation,
                    difficulty: .hard, loadout: .init(operatorClass: .engineer, camouflage: .vegetation))
                let game = try config.makeSimulation()
                let report = NativeRunReport(configuration: config, simulation: game, outcome: outcome)
                let view = NativeRunReportView(frame: NSRect(x: 0, y: 0, width: 720, height: 352))
                view.update(report); view.layoutSubtreeIfNeeded()
                #expect(report.accessibilityText.contains(outcome.title))
                #expect(report.accessibilityText.contains(String(UInt64.max)))
                for label in view.subviews.compactMap({ $0 as? NSTextField }) {
                    #expect(view.bounds.contains(label.frame))
                    let textHeight = (label.stringValue as NSString).boundingRect(with: NSSize(width: label.bounds.width, height: 1000),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: label.font!]).height
                    #expect(textHeight <= label.bounds.height, "Report clipped: \(label.stringValue)")
                }
            }
        }
    }
}
