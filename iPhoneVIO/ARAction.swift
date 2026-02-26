import SwiftUI
import Network

enum ARAction {
    case connectToEndpoint(NWEndpoint)
    case disconnect
    case resetOrigin
}
