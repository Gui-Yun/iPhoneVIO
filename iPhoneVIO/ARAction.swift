import SwiftUI

enum ARAction {
    case update(ip: String, port: Int)
    case resetOrigin
    case connect
    case disconnect
}
