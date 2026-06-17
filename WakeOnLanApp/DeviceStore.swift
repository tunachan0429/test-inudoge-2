import Foundation
import Combine

final class DeviceStore: ObservableObject {
    @Published var devices: [Device] = []

    private let storageKey = "wol_devices"

    init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Device].self, from: data) else {
            return
        }
        devices = decoded
    }

    func save() {
        if let encoded = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }

    func add(_ device: Device) {
        devices.append(device)
        save()
    }

    func update(_ device: Device) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
            save()
        }
    }

    func delete(at offsets: IndexSet) {
        devices.remove(atOffsets: offsets)
        save()
    }
}
