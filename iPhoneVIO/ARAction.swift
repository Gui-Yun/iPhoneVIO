import SwiftUI
import Network

enum ARAction {
    case connectToEndpoint(NWEndpoint)
    case disconnect
    case resetOrigin
    // FeasibleCap
    case startBasePlacement
    case toggleClutch
    case calibrateCamToTCP
    case resetGhostArm
}
