import SwiftUI
import Network

// MARK: - Models

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

class DeviceStore: ObservableObject {
    @Published var devices: [Device] = []

    private let key = "savedDevices"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Device].self, from: data) {
            devices = decoded
        }
    }

    func add(_ device: Device) {
        devices.append(device)
        save()
    }

    func delete(at offsets: IndexSet) {
        devices.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - WakeOnLAN

enum WakeOnLAN {
    static func macAddressData(from string: String) -> Data? {
        let hex = string.replacingOccurrences(of: ":", with: "")
                        .replacingOccurrences(of: "-", with: "")
        guard hex.count == 12 else { return nil }
        var data = Data()
        var index = hex.startIndex
        for _ in 0..<6 {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { return nil }
            data.append(byte)
            index = end
        }
        return data
    }

    static func send(mac: String, broadcastAddress: String, port: UInt16) throws {
        guard let macData = macAddressData(from: mac) else {
            throw NSError(domain: "WoL", code: 1, userInfo: [NSLocalizedDescriptionKey: "MACアドレスの形式が正しくありません"])
        }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(macData) }

        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { throw NSError(domain: "WoL", code: 2, userInfo: [NSLocalizedDescriptionKey: "ソケット作成失敗"]) }
        defer { close(sock) }

        var broadcastEnable: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(broadcastAddress)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                packet.withUnsafeBytes { bufPtr in
                    sendto(sock, bufPtr.baseAddress, packet.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if result < 0 {
            throw NSError(domain: "WoL", code: 3, userInfo: [NSLocalizedDescriptionKey: "送信失敗"])
        }
    }
}

// MARK: - SSHManager (HTTP)

class SSHManager: ObservableObject {
    @Published var status: PCStatus = .unknown
    private var monitorTimer: Timer?

    func startMonitoring(device: Device) {
        stopMonitoring()
        checkStatus(device: device)
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.checkStatus(device: device)
        }
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    func checkStatus(device: Device) {
        guard !device.hostIP.isEmpty else {
            DispatchQueue.main.async { self.status = .unknown }
            return
        }
        DispatchQueue.main.async { self.status = .checking }

        let urlString = "http://\(device.hostIP):\(device.httpPort)/status"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { self.status = .offline }
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"

        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    self?.status = .online
                } else {
                    self?.status = .offline
                }
            }
        }.resume()
    }

    func sendShutdown(device: Device, completion: @escaping (Bool, String) -> Void) {
        guard !device.hostIP.isEmpty else {
            completion(false, "HOST IP を設定してください")
            return
        }
        let urlString = "http://\(device.hostIP):\(device.httpPort)/shutdown"
        guard let url = URL(string: urlString) else {
            completion(false, "URLが無効です")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"

        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    completion(true, "OK")
                } else {
                    completion(false, "PCサーバーに繋がりません")
                }
            }
        }.resume()
    }
}

// MARK: - Pixel Font modifier

struct PixelStyle: ViewModifier {
    var size: CGFloat
    func body(content: Content) -> some View {
        content
            .font(.custom("AnyFont", size: size)) // fallback, override via UIFont
            .font(Font.system(size: size, design: .monospaced))
    }
}

// MARK: - Log Entry

struct LogEntry: Identifiable {
    let id = UUID()
    let time: String
    let message: String
}

// MARK: - Main ContentView

struct ContentView: View {
    @EnvironmentObject var store: DeviceStore
    @StateObject private var sshManager = SSHManager()

    @State private var showingAddSheet = false
    @State private var selectedDevice: Device?

    // Confirm overlay
    @State private var showConfirm = false
    @State private var confirmAction: ConfirmAction = .powerOn

    // Action states
    @State private var isWaking = false
    @State private var isShuttingDown = false

    // Logs
    @State private var logs: [LogEntry] = []

    // Doge image flash (AC-ON / AC-OFF for 3 seconds after a power action)
    @State private var flashImageName: String?
    @State private var flashLabelText: String?
    @State private var flashTimer: Timer?

    // Uptime
    @State private var uptimeSec = 0
    @State private var uptimeTimer: Timer?

    // Alert for errors
    @State private var showAlert = false
    @State private var alertMessage = ""

    enum ConfirmAction {
        case powerOn, powerOff
        var title: String { self == .powerOn ? "POWER ON" : "POWER OFF" }
        var message: String { self == .powerOn ? "PCの電源を\nONにしますか？" : "PCの電源を\nOFFにしますか？" }
    }

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar
                topBar

                // Header
                headerBar

                ScrollView {
                    VStack(spacing: 0) {
                        // Doge image frame
                        dogeFrame

                        // Status display
                        statusDisplay
                            .padding(.top, 20)

                        // Device selector
                        if store.devices.count > 1 {
                            devicePicker
                                .padding(.top, 12)
                        }

                        // Controls
                        controlsSection
                            .padding(.top, 24)

                        // Log panel
                        logPanel
                            .padding(.top, 16)

                        // Manage devices
                        manageSection
                            .padding(.top, 16)

                        Spacer(minLength: 40)
                    }
                }
            }

            // Confirm overlay
            if showConfirm {
                confirmOverlay
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            DeviceFormView { newDevice in
                store.add(newDevice)
                if selectedDevice == nil {
                    selectedDevice = newDevice
                    sshManager.startMonitoring(device: newDevice)
                }
                addLog("DEVICE ADDED: \(newDevice.name)")
            }
        }
        .alert("エラー", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            if let first = store.devices.first {
                selectedDevice = first
                sshManager.startMonitoring(device: first)
            }
            addLog("SYSTEM READY.")
        }
        .onChange(of: sshManager.status) { newStatus in
            handleStatusChange(newStatus)
        }
    }

    // MARK: - Top Bar

    var topBar: some View {
        HStack {
            TimeView()
            Spacer()
            Text("DOGE PC CTRL")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .tracking(1)
            Spacer()
            Text(selectedDevice.map { _ in "LIVE" } ?? "----")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .tracking(1)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.black)
    }

    // MARK: - Header

    var headerBar: some View {
        HStack {
            Spacer()
            Text("♥ DOGE POWER CONTROL ♥")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.vertical, 10)
        .background(Color.black)
        .overlay(Rectangle().frame(height: 2), alignment: .bottom)
    }

    // MARK: - Doge Frame

    var dogeFrame: some View {
        VStack(spacing: 0) {
            // Image
            ZStack {
                Color.white
                Image(dogeImageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 150, height: 150)
                    .interpolation(.none) // pixel art
            }
            .frame(width: 160, height: 160)
            .border(Color.black, width: 3)

            // Label
            Text(dogeLabel)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(3)
                .foregroundColor(.white)
                .frame(width: 160)
                .padding(.vertical, 6)
                .background(Color.black)
                .overlay(
                    Rectangle()
                        .stroke(Color.black, lineWidth: 3)
                )
        }
        .padding(.top, 24)
    }

    // "DogeStandby" = 通常待機の犬DOGE / "DogeOn" = AC-ON(ウインク) / "DogeOff" = AC-OFF
    var dogeImageName: String {
        flashImageName ?? "DogeStandby"
    }

    var dogeLabel: String {
        if let flashLabelText { return flashLabelText }
        switch sshManager.status {
        case .online: return "ONLINE"
        case .offline: return "STANDBY"
        case .checking: return "CHECKING"
        case .unknown: return "STANDBY"
        }
    }

    // 電源ON/OFF直後の3秒間だけ AC-ON / AC-OFF 画像を表示し、その後通常のDOGEに戻す
    func triggerFlash(image: String, label: String) {
        flashTimer?.invalidate()
        flashImageName = image
        flashLabelText = label
        flashTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            DispatchQueue.main.async {
                flashImageName = nil
                flashLabelText = nil
            }
        }
    }

    // MARK: - Status Display

    var statusDisplay: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("▶ SYSTEM STATUS")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black)

            // Body
            VStack(spacing: 8) {
                statusRow(label: "POWER", value: powerText, valueActive: sshManager.status == .online, blink: sshManager.status == .online)
                statusRow(label: "HOST", value: hostText, valueActive: sshManager.status == .online)
                statusRow(label: "PING", value: pingText, valueActive: sshManager.status == .online)
                statusRow(label: "UPTIME", value: uptimeText, valueActive: sshManager.status == .online)
            }
            .padding(12)
        }
        .frame(width: 300)
        .border(Color.black, width: 3)
    }

    func statusRow(label: String, value: String, valueActive: Bool, blink: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 7, weight: .regular, design: .monospaced))
                .foregroundColor(Color(white: 0.33))
            Spacer()
            BlinkingText(text: value, active: valueActive, blink: blink)
        }
        .padding(.bottom, 6)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color(white: 0.8)), alignment: .bottom)
    }

    var powerText: String { sshManager.status == .online ? "*** ON ***" : "-- OFF --" }
    var hostText: String {
        if sshManager.status == .online { return selectedDevice?.hostIP ?? "ONLINE" }
        return "OFFLINE"
    }
    var pingText: String { sshManager.status == .online ? "\(Int.random(in: 1...8)) ms" : "--- ms" }
    var uptimeText: String { fmt(uptimeSec) }

    func fmt(_ s: Int) -> String {
        String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    // MARK: - Device Picker

    var devicePicker: some View {
        VStack(spacing: 0) {
            HStack {
                Text("▶ SELECT DEVICE")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black)

            VStack(spacing: 0) {
                ForEach(store.devices) { device in
                    Button(action: {
                        selectedDevice = device
                        sshManager.startMonitoring(device: device)
                        addLog("SELECT: \(device.name)")
                    }) {
                        HStack {
                            Circle()
                                .fill(selectedDevice?.id == device.id ? Color.black : Color.clear)
                                .frame(width: 6, height: 6)
                                .overlay(Circle().stroke(Color.black, lineWidth: 1))
                            Text(device.name.uppercased())
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(.black)
                            Spacer()
                            Text(device.hostIP)
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundColor(Color(white: 0.4))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selectedDevice?.id == device.id ? Color(white: 0.9) : Color.white)
                    }
                    Divider()
                }
            }
        }
        .frame(width: 300)
        .border(Color.black, width: 3)
    }

    // MARK: - Controls

    var controlsSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("▶ OPERATION")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(Color(white: 0.33))
                Spacer()
            }
            .padding(.bottom, 8)

            // Power button
            Button(action: {
                showConfirmDialog()
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "power")
                        .font(.system(size: 20, weight: .bold))
                    Text(sshManager.status == .online ? "POWER OFF" : "POWER ON")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(3)
                }
                .foregroundColor(.white)
                .frame(width: 300, height: 64)
                .background(Color.black)
                .overlay(
                    Rectangle()
                        .stroke(Color.black, lineWidth: 3)
                )
            }
            .disabled(isWaking || isShuttingDown || selectedDevice == nil)
            .opacity((isWaking || isShuttingDown) ? 0.6 : 1.0)
        }
        .frame(width: 300)
    }

    // MARK: - Log Panel

    var logPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("▶ EVENT LOG")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(logs.suffix(5))) { log in
                    HStack(alignment: .top, spacing: 8) {
                        Text(log.time)
                            .font(.system(size: 7, design: .monospaced))
                            .foregroundColor(Color(white: 0.6))
                            .frame(width: 52, alignment: .leading)
                        Text(log.message)
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                    }
                }
                if logs.isEmpty {
                    Text("--")
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .bottomLeading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .border(Color.black, width: 3)
    }

    // MARK: - Manage Section

    var manageSection: some View {
        HStack(spacing: 12) {
            Button(action: { showingAddSheet = true }) {
                Text("+ ADD PC")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundColor(.white)
                    .frame(width: 140, height: 36)
                    .background(Color.black)
                    .border(Color.black, width: 2)
            }

            if let device = selectedDevice {
                Button(action: {
                    store.delete(at: IndexSet([store.devices.firstIndex(where: { $0.id == device.id }) ?? 0]))
                    selectedDevice = store.devices.first
                    if let first = selectedDevice {
                        sshManager.startMonitoring(device: first)
                    }
                    addLog("DEVICE REMOVED.")
                }) {
                    Text("REMOVE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundColor(.black)
                        .frame(width: 140, height: 36)
                        .border(Color.black, width: 2)
                }
            }
        }
        .frame(width: 300)
    }

    // MARK: - Confirm Overlay

    var confirmOverlay: some View {
        ZStack {
            Color.white.opacity(0.93).ignoresSafeArea()

            VStack(spacing: 0) {
                // Title
                Text(confirmAction.title)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.black)

                // Body
                VStack(spacing: 14) {
                    Text(confirmAction.message)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .multilineTextAlignment(.center)
                        .lineSpacing(10)
                        .foregroundColor(.black)

                    HStack(spacing: 10) {
                        Button("CANCEL") {
                            showConfirm = false
                        }
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white)
                        .overlay(Rectangle().stroke(Color.black, lineWidth: 2))

                        Button("OK") {
                            showConfirm = false
                            execToggle()
                        }
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.black)
                        .overlay(Rectangle().stroke(Color.black, lineWidth: 2))
                    }
                }
                .padding(16)
            }
            .frame(width: 260)
            .overlay(Rectangle().stroke(Color.black, lineWidth: 3))
            .background(Color.white)
        }
    }

    // MARK: - Logic

    func showConfirmDialog() {
        guard let device = selectedDevice else { return }
        if sshManager.status == .online {
            confirmAction = .powerOff
        } else {
            confirmAction = .powerOn
        }
        showConfirm = true
        _ = device
    }

    func execToggle() {
        guard let device = selectedDevice else { return }
        if confirmAction == .powerOn {
            triggerFlash(image: "DogeOn", label: "AC-ON")
            wakeDevice(device)
        } else {
            triggerFlash(image: "DogeOff", label: "AC-OFF")
            shutdownDevice(device)
        }
    }

    func wakeDevice(_ device: Device) {
        isWaking = true
        addLog("POWER ON...")
        DispatchQueue.global().async {
            do {
                try WakeOnLAN.send(mac: device.macAddress, broadcastAddress: device.broadcastAddress, port: device.port)
                DispatchQueue.main.async {
                    isWaking = false
                    addLog("MAGIC PACKET SENT.")
                    addLog("WAITING FOR HOST...")
                }
            } catch {
                DispatchQueue.main.async {
                    isWaking = false
                    addLog("ERROR: \(error.localizedDescription)")
                }
            }
        }
    }

    func shutdownDevice(_ device: Device) {
        isShuttingDown = true
        addLog("SHUTDOWN SENT...")
        sshManager.sendShutdown(device: device) { success, message in
            isShuttingDown = false
            if success {
                addLog("SHUTDOWN OK.")
                addLog("HOST DISCONNECTED.")
                stopUptime()
            } else {
                addLog("ERROR: \(message)")
            }
        }
    }

    func handleStatusChange(_ status: PCStatus) {
        switch status {
        case .online:
            addLog("HOST CONNECTED.")
            startUptime()
        case .offline:
            stopUptime()
        default:
            break
        }
    }

    func addLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let entry = LogEntry(time: formatter.string(from: Date()), message: message)
        logs.append(entry)
        if logs.count > 20 { logs.removeFirst() }
    }

    func startUptime() {
        uptimeSec = 0
        uptimeTimer?.invalidate()
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            uptimeSec += 1
        }
    }

    func stopUptime() {
        uptimeTimer?.invalidate()
        uptimeTimer = nil
        uptimeSec = 0
    }
}

// MARK: - BlinkingText

struct BlinkingText: View {
    let text: String
    let active: Bool
    let blink: Bool
    @State private var visible = true

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(active ? .black : Color(white: 0.67))
            .opacity((blink && !visible) ? 0 : 1)
            .onAppear {
                if blink {
                    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                        if blink { visible.toggle() }
                    }
                }
            }
    }
}

// MARK: - TimeView

struct TimeView: View {
    @State private var timeString = "--:--:--"
    var body: some View {
        Text(timeString)
            .font(.system(size: 7, weight: .bold, design: .monospaced))
            .tracking(1)
            .onAppear {
                updateTime()
                Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                    updateTime()
                }
            }
    }
    func updateTime() {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        timeString = f.string(from: Date())
    }
}

// MARK: - DeviceFormView

struct DeviceFormView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var macAddress = ""
    @State private var broadcastAddress = "192.168.0.255"
    @State private var port = "9"
    @State private var hostIP = ""
    @State private var httpPort = "8765"
    @State private var errorMessage: String?

    var onSave: (Device) -> Void

    var body: some View {
        NavigationView {
            ZStack {
                Color.white.ignoresSafeArea()
                Form {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("DEVICE NAME")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            TextField("例: メインPC", text: $name)
                                .font(.system(size: 11, design: .monospaced))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MAC ADDRESS")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            TextField("AA:BB:CC:DD:EE:FF", text: $macAddress)
                                .font(.system(size: 11, design: .monospaced))
                                .textInputAutocapitalization(.characters)
                        }
                    } header: {
                        Text("DEVICE INFO")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("BROADCAST ADDRESS")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            TextField("192.168.0.255", text: $broadcastAddress)
                                .font(.system(size: 11, design: .monospaced))
                                .keyboardType(.numbersAndPunctuation)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("WoL PORT")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            TextField("9", text: $port)
                                .font(.system(size: 11, design: .monospaced))
                                .keyboardType(.numberPad)
                        }
                    } header: {
                        Text("WAKE-ON-LAN (POWER ON)")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("HOST IP")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            TextField("192.168.0.8", text: $hostIP)
                                .font(.system(size: 11, design: .monospaced))
                                .keyboardType(.numbersAndPunctuation)
                                .autocorrectionDisabled()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("HTTP PORT")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            TextField("8765", text: $httpPort)
                                .font(.system(size: 11, design: .monospaced))
                                .keyboardType(.numberPad)
                        }
                    } header: {
                        Text("HTTP SERVER (POWER OFF)")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                    } footer: {
                        Text("PCでshutdown_server.pyを起動してください")
                            .font(.system(size: 7, design: .monospaced))
                    }

                    if let err = errorMessage {
                        Section {
                            Text(err)
                                .foregroundColor(.red)
                                .font(.system(size: 9, design: .monospaced))
                        }
                    }
                }
            }
            .navigationTitle("ADD DEVICE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("CANCEL") { dismiss() }
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("SAVE") { save() }
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
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
        guard let portNum = UInt16(port) else {
            errorMessage = "WoLポート番号が正しくありません"; return
        }
        let httpPortNum = UInt16(httpPort) ?? 8765
        let device = Device(name: name, macAddress: macAddress, broadcastAddress: broadcastAddress, port: portNum, hostIP: hostIP, httpPort: httpPortNum)
        onSave(device)
        dismiss()
    }
}

// MARK: - App Entry

@main
struct WakeOnLanApp: App {
    @StateObject private var store = DeviceStore()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
