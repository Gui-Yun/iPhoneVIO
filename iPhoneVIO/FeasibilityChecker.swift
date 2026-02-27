import Foundation

struct FeasibilityResult {
    let feasible: Bool
    let ikConverged: Bool
    let withinJointLimits: Bool
    let withinVelocityLimits: Bool
}

class FeasibilityChecker {
    private let joints: [JointDef]
    private var previousAngles: [Float]?
    private var previousTimestamp: Double = 0
    private let pauseThreshold: Double = 0.5  // Skip velocity check if Δt > 0.5s

    init(joints: [JointDef]) {
        self.joints = joints
    }

    func evaluate(ikResult: IKResult, timestamp: Double) -> FeasibilityResult {
        let q = ikResult.jointAngles

        // Check IK convergence
        let ikOk = ikResult.converged

        // Check joint position limits (redundant safety)
        var limitsOk = true
        for (i, angle) in q.enumerated() where i < joints.count {
            if angle < joints[i].posLower - 0.01 || angle > joints[i].posUpper + 0.01 {
                limitsOk = false
                break
            }
        }

        // Check joint velocity limits
        var velocityOk = true
        if let prevQ = previousAngles, previousTimestamp > 0 {
            let dt = timestamp - previousTimestamp
            if dt > 0.001 && dt < pauseThreshold {
                for (i, angle) in q.enumerated() where i < joints.count {
                    let rate = abs(angle - prevQ[i]) / Float(dt)
                    if rate > joints[i].velLimit {
                        velocityOk = false
                        break
                    }
                }
            }
        }

        // Update history
        previousAngles = q
        previousTimestamp = timestamp

        let feasible = ikOk && limitsOk && velocityOk
        return FeasibilityResult(feasible: feasible, ikConverged: ikOk,
                                 withinJointLimits: limitsOk, withinVelocityLimits: velocityOk)
    }

    func reset() {
        previousAngles = nil
        previousTimestamp = 0
    }
}
