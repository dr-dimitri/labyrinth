import Testing
import simd
@testable import BlacksiteCore

struct RunVariantTests {
    private let maps: [MapDefinition] = [.blacksite,.nebelwacht,.sundkai,.kessel9,.sirocco]

    @Test func everyPublishedMapHasExactlyThreeDistinctVersionedDeployments() throws {
        for map in maps {
            #expect(map.version == 2)
            let variants = try RunVariantCatalog.variants(for: map)
            #expect(variants.count == 3 && Set(variants.map(\.id)).count == 3)
            #expect(Set(variants.map { $0.map.dataSite }).count == 3)
            #expect(Set(variants.map { $0.map.patrolAnchors }).count == 3)
            for variant in variants {
                try variant.map.validateGameplay()
                #expect(variant.map.id == map.id && variant.map.version == map.version)
                #expect(variant.map.terrain == map.terrain && variant.map.resources == map.resources)
                #expect(variant.map.environment.vegetationZones.map(\.id) == map.environment.vegetationZones.map(\.id))
                #expect(variant.conditions.count == 3 && variant.conditions.allSatisfy { !$0.isEmpty && $0.count <= 100 })
                #expect(variant.map.patrolAnchors.count == 3)
                for stage in variant.map.operation?.requiredStages ?? [] where stage.kind == .collectData {
                    #expect(stage.targets.count == 1 && stage.targets[0].position == variant.map.dataSite)
                }
            }
        }
    }

    @Test func fullSeedAndDefinitionVersionChooseRepeatableVariantsWithoutMutatingBase() throws {
        for map in maps {
            let catalog = try RunVariantCatalog.variants(for: map)
            for seed: UInt64 in [0,1,2,1745,UInt64.max,0xFFFF_FFFF_0000_0001] {
                let first = try RunVariantCatalog.resolve(map: map,seed: seed)
                let second = try RunVariantCatalog.resolve(map: map,seed: seed)
                let expected = Int((seed%3 + UInt64(map.version-1)%3)%3)
                #expect(first.id == catalog[expected].id && first.id == second.id)
                #expect(first.conditions == second.conditions && first.map.dataSite == second.map.dataSite)
            }
            let low = try RunVariantCatalog.resolve(map: map,seed: 1)
            let high = try RunVariantCatalog.resolve(map: map,seed: 0x1_0000_0001)
            #expect(low.id != high.id, "The high seed bits must not be lost before variant selection")
            #expect(map.patrolAnchors.isEmpty && map.environment.devices.allSatisfy(\.initiallyEnabled))
        }
        let diagnostic = try RunVariantCatalog.resolve(map: .testRange,seed: UInt64.max)
        #expect(diagnostic.id == "standard" && diagnostic.map.id == MapDefinition.testRange.id)
        #expect(diagnostic.conditions.isEmpty)
    }

    @Test func initialDeviceGlassAndWeatherConditionsAreRealButNotCreditedAsActions() throws {
        for map in maps {
            let variants = try RunVariantCatalog.variants(for: map)
            for (index,variant) in variants.enumerated() {
                let game = CombatSimulation(map: variant.map,seed: UInt64(index),mission: .operation)
                #expect(game.runStatistics == RunStatistics())
                for definition in variant.map.environment.devices where definition.kind == .generator {
                    let generator = try #require(game.devices.first { $0.id == definition.id })
                    #expect(generator.enabled == (index != 1) && generator.powered == (index != 1))
                    for emitter in game.noiseEmitters where definition.noiseEmitterIDs.contains(emitter.id) {
                        #expect(emitter.enabled == generator.enabled)
                    }
                    for light in game.spotlights where definition.lightIDs.contains(light.id) {
                        #expect(light.enabled == generator.enabled)
                    }
                }
                if map.id == "blacksite" {
                    #expect(game.devices.first { $0.id == 1002 }?.gateProgress == (index == 1 ? 1 : 0))
                } else if map.id == "kessel9" {
                    let controller = try #require(game.devices.first { $0.id == 2950 })
                    #expect(controller.enabled == (index == 2) && controller.gateProgress == (index == 2 ? 1 : 0))
                    #expect(game.devices.first { $0.id == 2951 }?.gateProgress == (index == 2 ? 1 : 0))
                    #expect(game.devices.first { $0.id == 2952 }?.gateProgress == (index == 2 ? 0 : 1))
                } else if map.id == "sirocco" {
                    #expect(game.breaches.filter(\.isOpen).count == index)
                } else if map.id == "nebelwacht" {
                    for (source,original) in zip(variant.map.environment.smokeEmitters,map.environment.smokeEmitters) {
                        #expect(source.startDelay == original.startDelay + Float(index*3))
                        #expect(source.warningLeadTime == 3 && source.interval == 24)
                    }
                }
            }
        }
    }

    @Test func objectiveReinforcementsActuallyUseTheAuthoredVariantPatrolGoals() throws {
        for map in maps {
            for variant in try RunVariantCatalog.variants(for: map) {
                let game = CombatSimulation(map: variant.map,seed: 7,mission: .operation)
                game.step(deltaTime: 1.0/120,input: GameInput())
                #expect(!game.enemies.isEmpty && game.remainingEnemies == 4)
                for (index,enemy) in game.enemies.enumerated() {
                    let goal = variant.map.grounded(variant.map.patrolAnchors[index%3])
                    #expect(abs(enemy.yaw-atan2(goal.x-enemy.position.x,goal.z-enemy.position.z)) < 0.0001)
                }
            }
        }
    }

}
