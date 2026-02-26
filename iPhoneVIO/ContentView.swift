//
//  ContentView.swift
//  iPhoneVIO
//
//  Created by David Gao on 4/26/24.
//

import SwiftUI
import RealityKit
import SceneKit

struct ContentView : View {
    @ObservedObject var viewController: ViewController = ViewController()
    @ObservedObject var bonjourManager = BonjourManager.shared
    @StateObject var recordingController = RecordingController()
    @State private var autoConnected = false

    var statusColor: Color {
        switch viewController.connectionStatus {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .red
        }
    }

    var isConnected: Bool {
        viewController.connectionStatus == .connected
    }

    var body: some View {
        ARViewContainer(viewController: self.viewController)
            .edgesIgnoringSafeArea(.all)
            // Top status bar
            .overlay(alignment: .top) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 12, height: 12)
                    Text(viewController.displayString)
                        .font(.system(size: 14).monospaced())
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if !viewController.trackingStatus.isEmpty {
                        Text(viewController.trackingStatus)
                            .font(.system(size: 13, weight: .bold).monospaced())
                            .foregroundColor(.red)
                    }
                }
                .padding(10)
                .background(Color.black.opacity(0.6))
                .cornerRadius(8)
                .padding(.top, 50)
            }
            // Orientation cube (top-right)
            .overlay(alignment: .topTrailing) {
                OrientationCubeView(cameraTransform: viewController.cameraTransform)
                    .frame(width: 120, height: 120)
                    .padding(.top, 90)
                    .padding(.trailing, 8)
            }
            // mDNS status panel (top-left)
            .overlay(alignment: .topLeading) {
                MDNSStatusPanel(
                    bonjourManager: bonjourManager,
                    recordingController: recordingController,
                    connectionStatus: viewController.connectionStatus
                )
                .padding(.top, 90)
                .padding(.leading, 8)
            }
            // Recording button (bottom-center)
            .overlay(alignment: .bottom) {
                RecordingButton(
                    recordingController: recordingController,
                    isEnabled: recordingController.isReady || recordingController.isRecording
                )
                .padding(.bottom, 40)
            }
            // Error toast
            .overlay(alignment: .center) {
                if let error = recordingController.lastError {
                    Text(error)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.85))
                        .cornerRadius(10)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: recordingController.lastError)
            // Auto-connect to first discovered server
            .onChange(of: bonjourManager.discoveredServers) { _, servers in
                if !autoConnected && !isConnected && !servers.isEmpty {
                    let server = servers[0]
                    print("[Bonjour] Auto-connecting to \(server.name)")
                    ARManager.shared.actionStream.send(.connectToEndpoint(server.endpoint))
                    autoConnected = true
                }
            }
            // Retry on disconnect: reset flag and schedule reconnect
            .onChange(of: viewController.connectionStatus) { _, status in
                if status == .disconnected {
                    autoConnected = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        if viewController.connectionStatus == .disconnected,
                           !bonjourManager.discoveredServers.isEmpty {
                            let server = bonjourManager.discoveredServers[0]
                            print("[Bonjour] Reconnecting to \(server.name)")
                            ARManager.shared.actionStream.send(.connectToEndpoint(server.endpoint))
                            autoConnected = true
                        }
                    }
                }
            }
            // Sync rapidDriverURL to recording controller
            .onChange(of: bonjourManager.rapidDriverURL) { _, url in
                recordingController.updateBaseURL(url)
            }
    }
}

// MARK: - mDNS Status Panel

struct MDNSStatusPanel: View {
    @ObservedObject var bonjourManager: BonjourManager
    @ObservedObject var recordingController: RecordingController
    let connectionStatus: ConnectionStatus

    var readyStatusText: String {
        if bonjourManager.rapidDriverURL == nil {
            return "—"
        }
        return "\(recordingController.onlineDevices)/\(recordingController.totalDevices)"
    }

    var readyStatusColor: Color {
        if recordingController.isReady { return .green }
        if recordingController.totalDevices > 0 { return .yellow }
        return .gray
    }

    var dataStatusText: String {
        if connectionStatus == .connected {
            return "已连接"
        } else if !bonjourManager.discoveredServers.isEmpty {
            return "已发现"
        } else {
            return "搜索中"
        }
    }

    var dataStatusColor: Color {
        if connectionStatus == .connected { return .green }
        if !bonjourManager.discoveredServers.isEmpty { return .yellow }
        return .gray
    }

    var controlStatusText: String {
        bonjourManager.rapidDriverURL != nil ? "已发现" : "搜索中"
    }

    var controlStatusColor: Color {
        bonjourManager.rapidDriverURL != nil ? .green : .gray
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            StatusRow(
                label: "广播",
                status: bonjourManager.isAdvertising ? "✓" : "…",
                color: bonjourManager.isAdvertising ? .green : .gray
            )
            StatusRow(
                label: "数据",
                status: dataStatusText,
                color: dataStatusColor
            )
            StatusRow(
                label: "控制",
                status: controlStatusText,
                color: controlStatusColor
            )
            StatusRow(
                label: "就绪",
                status: readyStatusText,
                color: readyStatusColor
            )
        }
        .padding(10)
        .background(Color.black.opacity(0.6))
        .cornerRadius(8)
    }
}

struct StatusRow: View {
    let label: String
    let status: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11, weight: .medium).monospaced())
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 30, alignment: .leading)
            Text(status)
                .font(.system(size: 11).monospaced())
                .foregroundColor(.white)
        }
    }
}

// MARK: - Recording Button

struct RecordingButton: View {
    @ObservedObject var recordingController: RecordingController
    let isEnabled: Bool

    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 8) {
            Button {
                Task {
                    if recordingController.isRecording {
                        await recordingController.stopRecording()
                    } else {
                        await recordingController.startRecording()
                    }
                }
            } label: {
                ZStack {
                    // Outer ring
                    Circle()
                        .stroke(isEnabled ? Color.white : Color.gray, lineWidth: 4)
                        .frame(width: 72, height: 72)
                        .scaleEffect(recordingController.isRecording ? pulseScale : 1.0)

                    // Inner shape: circle when idle, rounded square when recording
                    if recordingController.isRecording {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red)
                            .frame(width: 30, height: 30)
                    } else {
                        Circle()
                            .fill(isEnabled ? Color.red : Color.gray)
                            .frame(width: 58, height: 58)
                    }
                }
            }
            .disabled(!isEnabled)
            .onChange(of: recordingController.isRecording) { _, recording in
                if recording {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulseScale = 1.1
                    }
                } else {
                    withAnimation(.default) {
                        pulseScale = 1.0
                    }
                }
            }

            // Duration label
            if recordingController.isRecording {
                Text(formatDuration(recordingController.recordingDuration))
                    .font(.system(size: 14, weight: .medium).monospaced())
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.7))
                    .cornerRadius(6)
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}


struct ARViewContainer: UIViewControllerRepresentable {

    @ObservedObject var viewController: ViewController

    func makeUIViewController(context: Context) -> ViewController {
        return self.viewController
    }

    func updateUIViewController(_ uiViewController: ViewController, context: Context) {
    }
}


#Preview {
    ContentView()
}
