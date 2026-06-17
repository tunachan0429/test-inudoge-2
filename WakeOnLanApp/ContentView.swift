import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: DeviceStore
    @StateObject private var sshManager = SSHManager()
    @State private var showingAddSheet = false
    @State private var selectedDevice: Device?
    @State private var alertMessage = ""
    @State private var alertTitle = ""
    @State private var showAlert = false
    @State private var isShuttingDown = false
    @State private var isWaking = false

    var body: some View {
        NavigationView {
            Group {
                if store.devices.isEmpty {
                    emptyState
                } else {
                    deviceList
                }
            }
            .navigationTitle("Doge Power Control")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingAddSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                DeviceFormView { newDevice in
                    store.add(newDevice)
                }
            }
            .alert(alertTitle, isPresented: $showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
        .onAppear {
            if let first = store.devices.first {
                selectedDevice = first
                sshManager.startMonitoring(device: first)
            }
        }
        .onChange(of: store.devices) { devices in
            if let selected = selectedDevice, !devices.contains(selected) {
                selectedDevice = devices.first
            }
            if selectedDevice == nil, let first = devices.first {
                selectedDevice = first
                sshManager.startMonitoring(device: first)
            }
        }
    }

    var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("PCが登録されていません")
                .font(.headline)
            Text("右上の + ボタンからPCを登録してください")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    var deviceList: some View {
        List {
            ForEach(store.devices) { device in
                VStack(spacing: 0) {
                    deviceRow(device)
                    if selectedDevice?.id == device.id {
                        controlPanel(device)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
            .onDelete(perform: store.delete)
        }
    }

    func deviceRow(_ device: Device) -> some View {
        Button(action: {
            selectedDevice = device
            sshManager.startMonitoring(device: device)
        }) {
            HStack(spacing: 12) {
                if selectedDevice?.id == device.id {
                    statusDot
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 10, height: 10)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(device.macAddress)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !device.hostIP.isEmpty {
                        Text("IP: \(device.hostIP)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Image(systemName: selectedDevice?.id == device.id ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    var statusDot: some View {
        ZStack {
            switch sshManager.status {
            case .online:
                Circle().fill(Color.green).frame(width: 10, height: 10)
            case .offline:
                Circle().fill(Color.red).frame(width: 10, height: 10)
            case .checking:
                ProgressView().scaleEffect(0.6).frame(width: 10, height: 10)
            case .unknown:
                Circle().fill(Color.gray).frame(width: 10, height: 10)
            }
        }
    }

    func controlPanel(_ device: Device) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                statusDot
                Text(statusLabel)
                    .font(.subheadline.bold())
                    .foregroundColor(statusColor)
                Spacer()
                Button(action: { sshManager.checkStatus(device: device) }) {
                    Label("更新", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemGroupedBackground))
            Divider()
            HStack(spacing: 12) {
                Button(action: { wake(device) }) {
                    Group {
                        if isWaking {
                            ProgressView().tint(.white)
                        } else {
                            Label("電源 ON", systemImage: "power")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(isWaking || sshManager.status == .online)

                Button(action: { shutdown(device) }) {
                    Group {
                        if isShuttingDown {
                            ProgressView().tint(.white)
                        } else {
                            Label("シャットダウン", systemImage: "power")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isShuttingDown || sshManager.status != .online)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemGroupedBackground))

            if device.hostIP.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("シャットダウンには HOST IP の設定が必要です")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .background(Color(.systemGroupedBackground))
            }
        }
    }

    var statusLabel: String {
        switch sshManager.status {
        case .online: return "ONLINE"
        case .offline: return "OFFLINE"
        case .checking: return "確認中..."
        case .unknown: return "未設定"
        }
    }

    var statusColor: Color {
        switch sshManager.status {
        case .online: return .green
        case .offline: return .red
        case .checking: return .orange
        case .unknown: return .secondary
        }
    }

    private func wake(_ device: Device) {
        isWaking = true
        DispatchQueue.global().async {
            do {
                try WakeOnLAN.send(
                    mac: device.macAddress,
                    broadcastAddress: device.broadcastAddress,
                    port: device.port
                )
                DispatchQueue.main.async {
                    isWaking = false
                    showAlertWith(
                        title: "送信完了",
                        message: "「\(device.name)」にマジックパケットを送信しました\nPCが起動するまで30〜60秒お待ちください"
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    isWaking = false
                    showAlertWith(title: "エラー", message: error.localizedDescription)
                }
            }
        }
    }

    private func shutdown(_ device: Device) {
        isShuttingDown = true
        sshManager.sendShutdown(device: device) { success, message in
            isShuttingDown = false
            showAlertWith(
                title: success ? "シャットダウン" : "エラー",
                message: success ? "「\(device.name)」をシャットダウンしています..." : message
            )
        }
    }

    private func showAlertWith(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}
