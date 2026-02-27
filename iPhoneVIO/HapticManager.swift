import CoreHaptics
import UIKit

class HapticManager {
    private var engine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    private var isWarning = false

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            engine = try CHHapticEngine()
            engine?.resetHandler = { [weak self] in
                try? self?.engine?.start()
            }
            engine?.stoppedHandler = { _ in }
            try engine?.start()
        } catch {
            print("[HapticManager] Engine init failed: \(error)")
        }
    }

    func startWarning() {
        guard !isWarning, let engine = engine else { return }
        isWarning = true

        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity, sharpness],
                                  relativeTime: 0, duration: 100)

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            continuousPlayer = try engine.makeAdvancedPlayer(with: pattern)
            try continuousPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("[HapticManager] Start warning failed: \(error)")
            isWarning = false
        }
    }

    func stopWarning() {
        guard isWarning else { return }
        isWarning = false
        try? continuousPlayer?.stop(atTime: CHHapticTimeImmediate)
        continuousPlayer = nil
    }

    func transientPulse() {
        guard let engine = engine else { return }
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness],
                                  relativeTime: 0)

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("[HapticManager] Transient pulse failed: \(error)")
        }
    }
}
