import SwiftUI

struct DeviceFormView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var macAddress: String = ""
    @State private var broadcastAddress: String = "192.168.0.255"
    @State private var port: String = "9"
    @State private var hostIP: String = ""
    @State private var httpPort: String = "8765"
    @State private var errorMessage: String?

    var onSave: (Device) -> Void

    var body: some View {
        NavigationView {
            Form {
                Section("デバイス情報") {
                    TextField("名前 (例: メインPC)", text: $name)
                    TextField("MACアドレス (例: AA:BB:CC:DD:EE:FF)", text: $macAddress)
                        .autocapitalization(.allCharacters)
                        .keyboardType(.asciiCapable)
                }

                Section {
                    TextField("ブロードキャストアドレス", text: $broadcastAddress)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("WoLポート番号", text: $port)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Wake-on-LAN設定（電源ON）")
                }

                Section {
                    TextField("ホストIP (例: 192.168.0.8)", text: $hostIP)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                    TextField("HTTPポート", text: $httpPort)
                        .keyboardType(.numberPad)
                } header: {
                    Text("HTTPサーバー設定（電源OFF・ステータス確認）")
                } footer: {
                    Text("PCでshutdown_server.pyを起動してください。デフォルトポートは8765です。")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("デバイスを追加")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { save() }
                        .bold()
                }
            }
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "名前を入力してください"; return
        }
        guard WakeOnLAN.macAddressData(from: macAddress) != nil else {
            errorMessage = "MACアドレスの形式が正しくありません"; return
        }
        guard let portNumber = UInt16(port) else {
            errorMessage = "WoLポート番号が正しくありません"; return
        }
        let httpPortNum = UInt16(httpPort) ?? 8765

        let device = Device(
            name: name,
            macAddress: macAddress,
            broadcastAddress: broadcastAddress,
            port: portNumber,
            hostIP: hostIP,
            httpPort: httpPortNum
        )
        onSave(device)
        dismiss()
    }
}
