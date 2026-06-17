import Foundation

enum WakeOnLANError: Error, LocalizedError {
    case invalidMACAddress
    case socketCreationFailed
    case sendFailed

    var errorDescription: String? {
        switch self {
        case .invalidMACAddress: return "MACアドレスの形式が正しくありません"
        case .socketCreationFailed: return "ソケットの作成に失敗しました"
        case .sendFailed: return "パケットの送信に失敗しました"
        }
    }
}

struct WakeOnLAN {

    /// マジックパケットを作成してブロードキャスト送信する
    static func send(mac: String, broadcastAddress: String, port: UInt16) throws {
        guard let macBytes = macAddressData(from: mac) else {
            throw WakeOnLANError.invalidMACAddress
        }

        // マジックパケット = 0xFF x6 + MACアドレス x16
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(macBytes)
        }

        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            throw WakeOnLANError.socketCreationFailed
        }
        defer { close(sock) }

        var broadcastEnable: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(broadcastAddress)

        let sent = withUnsafePointer(to: &addr) { ptr -> Int in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                packet.withUnsafeBytes { bufferPtr in
                    sendto(sock, bufferPtr.baseAddress, packet.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        guard sent == packet.count else {
            throw WakeOnLANError.sendFailed
        }
    }

    /// "AA:BB:CC:DD:EE:FF" のような文字列を6バイトのDataに変換する
    static func macAddressData(from mac: String) -> Data? {
        let cleaned = mac
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .uppercased()

        guard cleaned.count == 12, cleaned.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }

        var data = Data()
        var index = cleaned.startIndex
        for _ in 0..<6 {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
