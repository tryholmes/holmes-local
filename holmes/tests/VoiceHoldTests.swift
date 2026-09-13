import Foundation
import Carbon.HIToolbox

/// Standalone checks of the production hold/session state machines. No microphone,
/// recognizer, event monitors, permissions, or model server are started.
@main
struct VoiceHoldTests {
    @MainActor
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }

        let voice = VoiceInputController.shared
        expect(!voice.isListening, "Creating the voice controller must leave the microphone off")
        voice.beginListening(holdID: UUID())
        expect(!voice.isListening, "An arbitrary UI/programmatic call cannot start capture without an actual Fn hold")
        voice.cancelListening()
        expect(!voice.isListening, "Cancelling an idle voice controller must remain idle")

        var fn = FnHoldState()
        expect(fn.reconcile(physicalFnDown: true) == nil, "Launch polling must not start capture")
        expect(fn.handle(keyCode: UInt16(kVK_UpArrow), functionFlag: true, physicalFnDown: false) == nil,
               "Navigation function flags must not start capture")
        expect(fn.handle(keyCode: UInt16(kVK_Shift), functionFlag: true, physicalFnDown: true) == nil,
               "Another modifier's event must not initiate a hold")
        expect(fn.handle(keyCode: UInt16(kVK_Function), functionFlag: true, physicalFnDown: false) == nil,
               "A synthetic Fn flag must not initiate a hold")
        guard case .began(let first)? = fn.handle(keyCode: UInt16(kVK_Function), functionFlag: true, physicalFnDown: true) else {
            fatalError("A physical Fn press should begin")
        }
        expect(fn.handle(keyCode: UInt16(kVK_Function), functionFlag: true, physicalFnDown: true) == nil,
               "Repeated/local-global duplicate events must not begin twice")
        expect(fn.handle(keyCode: UInt16(kVK_Shift), functionFlag: true, physicalFnDown: true) == nil,
               "Modifiers while Fn is held must retain the current session")
        expect(fn.reconcile(physicalFnDown: false) == .ended(first), "Watchdog must end a missed release")
        expect(fn.reconcile(physicalFnDown: false) == nil, "Release must be delivered once")
        guard case .began(let second)? = fn.handle(keyCode: UInt16(kVK_Function), functionFlag: true, physicalFnDown: true) else {
            fatalError("A second physical press should begin")
        }
        expect(first != second, "Each physical hold needs a new ID")
        expect(fn.cancel() == .cancelled(second), "Sleep/session exit must cancel a hold")
        expect(fn.activeID == nil, "Cancelled holds must lose capture authorization")

        var session = VoiceHoldSession()
        session.begin(first)
        expect(!session.release(first), "Release during permissions must not finalize speech")
        expect(!session.authorize(first, isHeld: true, permissionGranted: true),
               "Late permission result for a released hold must never start capture")
        session.begin(second)
        expect(!session.authorize(first, isHeld: true, permissionGranted: true),
               "An older permission result must not start a newer hold")
        expect(session.authorize(second, isHeld: true, permissionGranted: true), "Current authorized hold can capture")
        expect(!session.release(first), "Queued release for the previous hold cannot stop the current hold")
        expect(!session.acceptsRecognition(first), "Old speech callbacks cannot update the current transcript")
        expect(session.acceptsRecognition(second), "Current recognition callbacks are accepted")
        expect(!session.finish(second), "A recognizer final cannot submit an action while Fn remains held")
        session.recognitionEnded(second)
        expect(!session.acceptsRecognition(second), "Callbacks after early recognition end must be ignored")
        expect(session.release(second), "Releasing an early-finished recognizer must finalize its transcript")
        expect(session.finish(second), "A released transcript should deliver once")
        expect(!session.finish(second), "Recognizer and fallback cannot deliver twice")

        session.begin(first)
        expect(!session.authorize(first, isHeld: false, permissionGranted: true),
               "Physical release must prevent recording even if the release event is queued")
        session.begin(first)
        expect(!session.authorize(first, isHeld: true, permissionGranted: false), "Denied permissions cannot capture")
        session.begin(first)
        expect(session.authorize(first, isHeld: true, permissionGranted: true), "First hold starts")
        expect(session.release(first), "First hold starts finalizing")
        session.begin(second)
        expect(!session.finish(first), "Old fallback timer cannot finish a superseding hold")
        session.cancel(first)
        expect(session.holdID == second, "Old cancellation cannot cancel a superseding hold")
        session.cancel(second)
        expect(session.holdID == nil, "Shutdown cancellation clears the active hold")

        // The microphone is already off after release, but its transcript can
        // still be finalizing. A lifecycle event must cancel that pending result
        // even though HotkeyManager no longer owns an active Fn ID.
        var pendingTranscript = VoiceHoldSession()
        pendingTranscript.begin(first)
        expect(pendingTranscript.authorize(first, isHeld: true, permissionGranted: true), "Lifecycle scenario starts capture")
        expect(pendingTranscript.release(first), "Lifecycle scenario releases before recognition finishes")
        var lifecycleCancellationDelivered = false
        HotkeyManager.shared.onPushToTalkCancel = { holdID in
            expect(holdID == nil, "Cancellation after key-up must reach the voice owner without an active hold ID")
            lifecycleCancellationDelivered = true
            pendingTranscript.cancel(holdID)
        }
        HotkeyManager.shared.cancelPushToTalk()
        expect(lifecycleCancellationDelivered, "Lifecycle cancellation must be delivered synchronously")
        expect(!pendingTranscript.finish(first), "Sleep or lock after release must discard the pending transcript")
        HotkeyManager.shared.onPushToTalkCancel = nil

        var physicalFnDown = true
        var buffersConsumed = 0
        let gate = VoiceAudioGate { physicalFnDown }
        gate.whileHeld { buffersConsumed += 1 }
        expect(buffersConsumed == 1, "Held audio is delivered")
        physicalFnDown = false
        gate.whileHeld { buffersConsumed += 1 }
        expect(buffersConsumed == 1, "Released hardware blocks audio even before the main actor handles release")
        physicalFnDown = true
        gate.whileHeld { buffersConsumed += 1 }
        expect(buffersConsumed == 1, "An old audio tap must not resume on the next press")
        let closedGate = VoiceAudioGate { true }
        closedGate.close()
        closedGate.whileHeld { buffersConsumed += 1 }
        expect(buffersConsumed == 1, "Cancelled audio gates never deliver a queued buffer")
        print("Passed \(checks) voice hold regression checks")
    }
}
