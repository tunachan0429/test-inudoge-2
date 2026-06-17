import Foundation
import Network

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

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200 {
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

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200 {
                    completion(true, "シャットダウンコマンドを送信しました")
                } else {
                    completion(false, "送信失敗: PCサーバーに繋がりません\n\nPC側でshutdown_server.pyが起動しているか確認してください")
                }
            }
        }.resume()
    }
}
