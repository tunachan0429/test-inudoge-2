import Foundation

struct Device: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var macAddress: String
    var broadcastAddress: String = "255.255.255.255"
    var port: UInt16 = 9
    var hostIP: String = ""
    var httpPort: UInt16 = 8765
}

enum PCStatus: Equatable {
    case online, offline, checking, unknown
}
