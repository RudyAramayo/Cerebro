import Foundation

/// ROBArmSide names the robot's physical side. Amber's historical gateway
/// keys name the vendor cores instead: "left" is L10 on ROB-right, and
/// "right" is R11 on ROB-left. Convert only at the gateway boundary.
extension ROBArmSide {
    var amberGatewayArm: String { self == .left ? "right" : "left" }
    var amberCoreName: String { self == .left ? "R11" : "L10" }
    var amberUDPPort: Int { self == .left ? 26002 : 26001 }
    var amberRoutingDescription: String {
        "Robot \(rawValue.capitalized) • \(amberCoreName) • UDP \(amberUDPPort)"
    }

    init?(amberGatewayArm: String) {
        switch amberGatewayArm.lowercased() {
        case "left": self = .right
        case "right": self = .left
        default: return nil
        }
    }
}
