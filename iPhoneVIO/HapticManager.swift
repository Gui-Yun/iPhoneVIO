import CoreHaptics
import UIKit

class HapticManager {
    private var engine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    private var currentMode: WarningMode = .none

    enum WarningMode {
        case none
        case mild       // approaching singularity: low intensity intermittent
        case strong     // infeasible: high intensity continuous
    }

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

    /// Start or switch to the specified warning mode
    func setWarningMode(_ mode: WarningMode) {
        guard mode != currentMode else { return }

        // Stop current player
        if currentMode != .none {
            try? continuousPlayer?.stop(atTime: CHHapticTimeImmediate)
            continuousPlayer = nil
        }

        currentMode = mode

        guard mode != .none, let engine = engine else { return }

        do {
            let pattern: CHHapticPattern
            switch mode {
            case .mild:
                // Intermittent low-intensity pulses (repeating pattern)
                var events: [CHHapticEvent] = []
                let count = 50  // enough for ~50s
                for i in 0..<count {
                    let t = Double(i) * 1.0  // one pulse per second
                    let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.3)
                    let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)
                    events.append(CHHapticEvent(eventType: .hapticContinuous,
                                                parameters: [intensity, sharpness],
                                                relativeTime: t, duration: 0.15))
                }
                pattern = try CHHapticPattern(events: events, parameters: [])

            case .strong:
                // Continuous high-intensity warning
                let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6)
                let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
                let event = CHHapticEvent(eventType: .hapticContinuous,
                                          parameters: [intensity, sharpness],
                                          relativeTime: 0, duration: 100)
                pattern = try CHHapticPattern(events: [event], parameters: [])

            case .none:
                return
            }

            continuousPlayer = try engine.makeAdvancedPlayer(with: pattern)
            try continuousPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("[HapticManager] Warning mode \(mode) failed: \(error)")
            currentMode = .none
        }
    }

    func stopWarning() {
        setWarningMode(.none)
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
