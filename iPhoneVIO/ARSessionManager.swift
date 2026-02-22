//
//  ARSessionManager.swift
//  iPhoneVIO
//
//  Created by David Gao on 4/26/24.
//

import Foundation
import ARKit
import RealityKit
import Combine

class ViewController: UIViewController, ARSessionDelegate, ObservableObject {
    @Published var displayString: String = ""
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var displayMode: Int = 0
    @Published var trackingStatus: String = ""
    @Published var cameraTransform: simd_float4x4 = matrix_identity_float4x4

    var arView: ARView!
    let networkClient = NetworkClient()
    var hostIP: String = "10.90.0.133"

    var hostPort: Int = 5555
    var prevTimestamp: Double = 0.0

    private let jpegQueue = DispatchQueue(label: "com.iphoneVIO.jpeg", qos: .userInitiated)
    private let ciContext = CIContext()
    private var sessionId = UUID().uuidString
    private var hasSentMetadata = false
    private var jpegQuality: CGFloat = 0.7

    // AR guides
    private var originAnchor: AnchorEntity?
    private var normalFrameCount: Int = 0
    private let normalFrameThreshold: Int = 10

    override func viewDidLoad() {
        super.viewDidLoad()

        arView = ARView(frame: view.bounds)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.debugOptions.insert(.showFeaturePoints)
        view.addSubview(arView)

        networkClient.onStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                self?.connectionStatus = status
            }
        }
        setupARSession()
        subscribeToActionStream()
    }

    func setupARSession() {
        hasSentMetadata = false
        sessionId = UUID().uuidString
        networkClient.connect(hostIP: hostIP, hostPort: hostPort)
        self.publishPose = true
        arView.session.delegate = self
        let configuration = ARWorldTrackingConfiguration()
        arView.session.run(configuration)
        setupARGuides()
    }

    // MARK: - AR Visual Guides

    func setupARGuides() {
        if let old = originAnchor { arView.scene.anchors.remove(old) }

        let origin = AnchorEntity(world: .zero)
        let axisLength: Float = 0.15
        let axisThick: Float = 0.004

        // X — red
        let xAxis = ModelEntity(
            mesh: .generateBox(width: axisLength, height: axisThick, depth: axisThick),
            materials: [UnlitMaterial(color: .red)])
        xAxis.position = SIMD3(axisLength / 2, 0, 0)
        origin.addChild(xAxis)

        // Y — green
        let yAxis = ModelEntity(
            mesh: .generateBox(width: axisThick, height: axisLength, depth: axisThick),
            materials: [UnlitMaterial(color: .green)])
        yAxis.position = SIMD3(0, axisLength / 2, 0)
        origin.addChild(yAxis)

        // Z — blue
        let zAxis = ModelEntity(
            mesh: .generateBox(width: axisThick, height: axisThick, depth: axisLength),
            materials: [UnlitMaterial(color: .blue)])
        zAxis.position = SIMD3(0, 0, axisLength / 2)
        origin.addChild(zAxis)

        // Origin sphere
        let sphere = ModelEntity(
            mesh: .generateSphere(radius: 0.008),
            materials: [UnlitMaterial(color: .white)])
        origin.addChild(sphere)

        arView.scene.addAnchor(origin)
        originAnchor = origin
    }

    // MARK: - Action Stream

    private var cancellables: Set<AnyCancellable> = []
    private var publishPose: Bool = false

    func subscribeToActionStream() {

        ARManager.shared
            .actionStream
            .sink { [weak self] action in
                switch action {
                    case .update(let ip, let port):
                        self?.publishPose = false
                        self?.networkClient.disconnect()
                        self?.hostIP = ip
                        self?.hostPort = port
                        self?.hasSentMetadata = false
                        self?.sessionId = UUID().uuidString
                        print("Reconnecting to \(ip):\(port)")
                        self?.networkClient.connect(hostIP: ip, hostPort: port)
                        self?.publishPose = true
                    case .resetOrigin:
                        self?.hasSentMetadata = false
                        self?.sessionId = UUID().uuidString
                        let configuration = ARWorldTrackingConfiguration()
                        self?.arView.session.run(configuration, options: .resetTracking)
                        self?.setupARGuides()
                    case .connect:
                        guard let self = self else { return }
                        self.hasSentMetadata = false
                        self.sessionId = UUID().uuidString
                        self.networkClient.connect(hostIP: self.hostIP, hostPort: self.hostPort)
                        self.publishPose = true
                    case .disconnect:
                        self?.publishPose = false
                        self?.networkClient.disconnect()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let transform = frame.camera.transform
        let timestamp = frame.timestamp
        let wallClock = Date().timeIntervalSince1970
        let fps = prevTimestamp > 0 ? 1 / (timestamp - prevTimestamp) : 0

        switch displayMode {
        case 1:
            let euler = frame.camera.eulerAngles
            let roll = euler.x * 180 / .pi
            let pitch = euler.y * 180 / .pi
            let yaw = euler.z * 180 / .pi
            displayString = String(format: "x:%.3f y:%.3f z:%.3f r:%.1f p:%.1f yaw:%.1f fps:%.0f",
                                   transform[3][0], transform[3][1], transform[3][2],
                                   roll, pitch, yaw, fps)
        case 2:
            displayString = String(format: "fps: %.0f", fps)
        default:
            displayString = String(format: "x:%.4f y:%.4f z:%.4f fps:%.0f",
                                   transform[3][0], transform[3][1], transform[3][2], fps)
        }

        cameraTransform = transform
        prevTimestamp = timestamp

        // Per-frame tracking quality (debounce: clear after 10 consecutive normal frames)
        switch frame.camera.trackingState {
        case .normal:
            normalFrameCount += 1
            if normalFrameCount >= normalFrameThreshold {
                trackingStatus = ""
            }
        case .limited(let reason):
            normalFrameCount = 0
            switch reason {
            case .excessiveMotion:      trackingStatus = "Too fast!"
            case .insufficientFeatures: trackingStatus = "Low features"
            case .initializing:         trackingStatus = "Initializing"
            case .relocalizing:         trackingStatus = "Relocalizing"
            @unknown default:           trackingStatus = "Limited"
            }
        case .notAvailable:
            normalFrameCount = 0
            trackingStatus = "No tracking"
        }

        guard publishPose else { return }

        // Send session metadata once (on first frame after connect)
        if !hasSentMetadata {
            let intrinsics = frame.camera.intrinsics
            let resolution = frame.camera.imageResolution
            let metadata = SessionMetadata(
                sessionId: sessionId,
                deviceModel: Self.deviceModelIdentifier(),
                imageWidth: Int(resolution.width),
                imageHeight: Int(resolution.height),
                focalLengthX: intrinsics[0][0],
                focalLengthY: intrinsics[1][1],
                principalPointX: intrinsics[2][0],
                principalPointY: intrinsics[2][1],
                arkitTimestamp0: timestamp,
                wallClock0: wallClock
            )
            networkClient.sendSessionMetadata(metadata)
            hasSentMetadata = true
        }

        // Backpressure: skip frame if still sending previous
        guard !networkClient.isSending else { return }

        // Compress JPEG on background queue
        let pixelBuffer = frame.capturedImage
        jpegQueue.async { [weak self] in
            guard let self else { return }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let jpeg = self.ciContext.jpegRepresentation(
                of: ciImage,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: self.jpegQuality]
            ) else { return }
            let packet = FramePacket(
                transform: transform,
                deviceTimestamp: timestamp,
                wallClock: wallClock,
                jpegData: jpeg
            )
            self.networkClient.sendFrame(packet)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        arView.session.pause()
    }

    static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
        return machine
    }
}
