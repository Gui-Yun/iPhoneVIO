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
    @State private var newHostIP: String = "10.90.0.133"
    @State private var newHostPort: String = "5555"

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
            .overlay(alignment: .topTrailing) {
                OrientationCubeView(cameraTransform: viewController.cameraTransform)
                    .frame(width: 120, height: 120)
                    .padding(.top, 90)
                    .padding(.trailing, 8)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    HStack {
                        TextField("Host IP", text: $newHostIP)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        TextField("Host Port", text: $newHostPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(12)

                    HStack(spacing: 16) {
                        // Connect / Disconnect
                        Button {
                            if isConnected {
                                ARManager.shared.actionStream.send(.disconnect)
                            } else {
                                ARManager.shared.actionStream.send(.connect)
                            }
                        } label: {
                            Image(systemName: isConnected ? "wifi" : "wifi.slash")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 24, height: 24)
                                .padding(12)
                                .background(.regularMaterial)
                                .cornerRadius(12)
                        }

                        // Reset Origin
                        Button {
                            ARManager.shared.actionStream.send(.resetOrigin)
                        } label: {
                            Image(systemName: "location.circle")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 24, height: 24)
                                .padding(12)
                                .background(.regularMaterial)
                                .cornerRadius(12)
                        }

                        // Display Mode Toggle
                        Button {
                            viewController.displayMode = (viewController.displayMode + 1) % 3
                        } label: {
                            Image(systemName: "info.circle")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 24, height: 24)
                                .padding(12)
                                .background(.regularMaterial)
                                .cornerRadius(12)
                        }

                        // Reconnect with new IP/Port
                        Button {
                            ARManager.shared.actionStream.send(.update(ip: newHostIP, port: Int(newHostPort) ?? 5555))
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 24, height: 24)
                                .padding(12)
                                .background(.regularMaterial)
                                .cornerRadius(12)
                        }
                    }
                }
                .padding(.bottom, 30)
            }
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
