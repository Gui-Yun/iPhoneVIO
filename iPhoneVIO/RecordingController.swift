//
//  RecordingController.swift
//  iPhoneVIO
//
//  Controls recording via rapid_driver HTTP API.
//

import Foundation

class RecordingController: ObservableObject {
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var lastError: String?
    @Published var isReady = false
    @Published var onlineDevices = 0
    @Published var totalDevices = 0

    private var timer: Timer?
    private var readyPoller: Timer?
    private var baseURL: URL?

    func updateBaseURL(_ url: URL?) {
        baseURL = url
        // If server disappeared while recording, stop the timer
        if url == nil && isRecording {
            stopTimer()
            isRecording = false
        }
        if url != nil {
            startReadyPolling()
        } else {
            stopReadyPolling()
            isReady = false
            onlineDevices = 0
            totalDevices = 0
        }
    }

    func startRecording() async {
        guard let baseURL = baseURL else { return }

        let url = baseURL.appendingPathComponent("recording/start")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["session_id": UUID().uuidString]
        request.httpBody = try? JSONEncoder().encode(body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               (200..<300).contains(httpResponse.statusCode) {
                await MainActor.run {
                    self.isRecording = true
                    self.recordingDuration = 0
                    self.startTimer()
                }
            } else {
                await setError("Server returned error")
            }
        } catch {
            await setError("Connection failed")
        }
    }

    func stopRecording() async {
        guard let baseURL = baseURL else { return }

        let url = baseURL.appendingPathComponent("recording/stop")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               (200..<300).contains(httpResponse.statusCode) {
                await MainActor.run {
                    self.isRecording = false
                    self.stopTimer()
                }
            } else {
                await setError("Server returned error")
            }
        } catch {
            await setError("Connection failed")
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.recordingDuration += 1.0
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        recordingDuration = 0
    }

    // MARK: - Ready Polling

    private func startReadyPolling() {
        readyPoller?.invalidate()
        pollReady() // immediate first check
        readyPoller = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollReady()
        }
    }

    private func stopReadyPolling() {
        readyPoller?.invalidate()
        readyPoller = nil
    }

    private func pollReady() {
        guard let baseURL = baseURL else { return }
        let url = baseURL.appendingPathComponent("ready")
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let ready = json["ready"] as? Bool ?? false
                    let online = json["online"] as? Int ?? 0
                    let total = json["total"] as? Int ?? 0
                    await MainActor.run {
                        self.isReady = ready
                        self.onlineDevices = online
                        self.totalDevices = total
                    }
                }
            } catch {
                await MainActor.run {
                    self.isReady = false
                }
            }
        }
    }

    @MainActor
    private func setError(_ message: String) {
        lastError = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.lastError = nil
        }
    }
}
