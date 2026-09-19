import Testing
@testable import BlacksiteMac

struct NativeInputStateTests {
    @Test func movementAliasesCancelOpposingDirectionsWithoutDoublingSpeed() {
        var state = NativeInputState()
        state.press(.key(13)); state.press(.key(126))
        #expect(state.snapshot().moveForward == 1)
        state.press(.key(1))
        #expect(state.snapshot().moveForward == 0)
        state.release(.key(13))
        #expect(state.snapshot().moveForward == 0)
        state.release(.key(1))
        #expect(state.snapshot().moveForward == 1)
        state.release(.key(126)); state.press(.key(0))
        #expect(state.snapshot().moveForward == 0 && state.snapshot().moveRight == -1)
        state.press(.key(2))
        #expect(state.snapshot().moveRight == 0)
        state.release(.key(0))
        #expect(state.snapshot().moveRight == 1)
    }

    @Test func arrowsAndPageKeysPreserveTheirExistingLookDirections() {
        var state = NativeInputState()
        state.press(.key(123)); state.press(.key(116))
        #expect(state.snapshot().yawAxis == 1 && state.snapshot().pitchAxis == 1)
        state.press(.key(124)); state.press(.key(121))
        #expect(state.snapshot().yawAxis == 0 && state.snapshot().pitchAxis == 0)
        state.release(.key(123)); state.release(.key(116))
        #expect(state.snapshot().yawAxis == -1 && state.snapshot().pitchAxis == -1)
        #expect(state.snapshot().moveRight == 0)
    }

    @Test func shortFireTapSurvivesReleaseAndDisplayFramesUntilARealSimulationStep() {
        var state = NativeInputState()
        #expect(state.press(.mouse(0)) == [.fire])
        state.release(.mouse(0))
        for _ in 0..<10 { #expect(state.snapshot().fire) }
        state.didAdvanceSimulation()
        #expect(!state.snapshot().fire)
        state.press(.key(12))
        state.didAdvanceSimulation()
        #expect(state.snapshot().fire) // Automatic fire continues while held.
        state.release(.key(12))
        #expect(!state.snapshot().fire)
    }

    @Test func heldAimAndSprintFollowReleaseWhileAliasesRemainIndependent() {
        var state = NativeInputState()
        state.press(.mouse(1)); state.press(.key(6)); state.press(.modifier(.shift))
        #expect(state.snapshot().aim && state.snapshot().sprint)
        state.release(.mouse(1))
        #expect(state.snapshot().aim)
        state.release(.key(6)); state.release(.modifier(.shift))
        #expect(!state.snapshot().aim && !state.snapshot().sprint)
        state.press(.mouse(0)); state.press(.key(12)); state.didAdvanceSimulation()
        state.release(.mouse(0))
        #expect(state.snapshot().fire)
        state.release(.key(12))
        #expect(!state.snapshot().fire)
    }

    @Test func toggleModesChangeOnlyOnFreshPressesAndIgnoreRepeatOrDuplicateDown() {
        var state = NativeInputState(aimMode: .toggle, sprintMode: .toggle)
        #expect(state.press(.mouse(1)) == [.aim])
        #expect(state.press(.mouse(1)).isEmpty)
        #expect(state.press(.mouse(1), isRepeat: true).isEmpty)
        state.release(.mouse(1))
        #expect(state.snapshot().aim)
        state.press(.key(6)); state.release(.key(6))
        #expect(!state.snapshot().aim)
        state.press(.modifier(.shift)); state.release(.modifier(.shift))
        #expect(state.snapshot().sprint)
        #expect(state.press(.modifier(.shift), isRepeat: true).isEmpty)
        #expect(state.snapshot().sprint)
        state.press(.modifier(.shift))
        #expect(!state.snapshot().sprint)
    }

    @Test func interactionHasOneDiscreteMantleOpportunityAndASeparateHeldState() {
        var state = NativeInputState()
        #expect(state.press(.key(14)) == [.interact])
        #expect(state.snapshot().interact)
        #expect(state.press(.key(14), isRepeat: true).isEmpty)
        #expect(state.press(.key(14)).isEmpty)
        state.didAdvanceSimulation()
        #expect(state.snapshot().interact)
        state.release(.key(14))
        #expect(!state.snapshot().interact)
        #expect(state.press(.key(14)) == [.interact])
        #expect(state.press(.key(49)) == [.jump])
        #expect(state.press(.key(49), isRepeat: true).isEmpty)
    }

    @Test func wheelPulsesNeverCreateHeldActionsAndCanLatchOneFireAttempt() {
        var state = NativeInputState()
        let neutral = state.snapshot()
        #expect(state.pulse(.up) == [.nextWeapon])
        #expect(state.pulse(.down) == [.nextWeapon])
        #expect(state.snapshot() == neutral)
        var bindings = NativeBindings.defaults
        bindings.assign(nil, to: .nextWeapon, slot: .primary)
        bindings.assign(.wheel(.up), to: .fire, slot: .primary)
        state.reconfigure(bindings: bindings, aimMode: .hold, sprintMode: .hold)
        #expect(state.pulse(.up) == [.fire] && state.snapshot().fire)
        state.didAdvanceSimulation()
        #expect(state.snapshot() == neutral)
        #expect(state.press(.wheel(.up)) == [.fire])
        state.didAdvanceSimulation()
        #expect(state.snapshot() == neutral)
    }

    @Test func clearRemovesMovementFireAndTogglesAndLateEventsCannotRelatch() {
        var state = NativeInputState(aimMode: .toggle, sprintMode: .toggle)
        let neutral = state.snapshot()
        state.press(.key(13)); state.press(.key(14)); state.press(.mouse(0)); state.release(.mouse(0))
        state.press(.mouse(1)); state.press(.modifier(.shift))
        state.clear()
        #expect(state.snapshot() == neutral)
        state.release(.mouse(1)); state.release(.modifier(.shift)); state.release(.key(14)); state.release(.key(13))
        #expect(state.press(.key(12), isRepeat: true).isEmpty)
        #expect(state.snapshot() == neutral)
        #expect(state.press(.key(12)) == [.fire] && state.snapshot().fire)
    }

    @Test func reconfigurationClearsTheOldProfileBeforeNewInputsCanAct() {
        var state = NativeInputState(aimMode: .toggle, sprintMode: .toggle)
        state.press(.mouse(0)); state.press(.mouse(1)); state.press(.modifier(.shift)); state.press(.key(13))
        var bindings = NativeBindings.defaults
        bindings.assign(.key(17), to: .fire, slot: .primary)
        state.reconfigure(bindings: bindings, aimMode: .hold, sprintMode: .hold)
        #expect(state.snapshot() == NativeInputState().snapshot())
        state.release(.mouse(0)); state.release(.mouse(1)); state.release(.modifier(.shift))
        #expect(state.press(.mouse(0)).isEmpty)
        #expect(state.press(.key(17)) == [.fire])
        state.release(.key(17))
        #expect(state.snapshot().fire)
        state.didAdvanceSimulation()
        #expect(!state.snapshot().fire)
    }
}
