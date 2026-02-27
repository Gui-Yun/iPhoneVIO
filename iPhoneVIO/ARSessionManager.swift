//
//  ARSessionManager.swift
//  iPhoneVIO
//
//  Created by David Gao on 4/26/24.
//

import Foundation
import ARKit
import SceneKit
import Combine

class ViewController: UIViewController, ARSessionDelegate, ObservableObject {
    @Published var displayString: String = ""
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var displayMode: Int = 0
    @Published var trackingStatus: String = ""
    @Published var cameraTransform: simd_float4x4 = matrix_identity_float4x4

    var scnView: ARSCNView!
    let networkClient = NetworkClient()
    var prevTimestamp: Double = 0.0

    private let jpegQueue = DispatchQueue(label: "com.iphoneVIO.jpeg", qos: .userInitiated)
    private let ciContext = CIContext()
    private var sessionId = UUID().uuidString
    private var hasSentMetadata = false
    private var jpegQuality: CGFloat = 0.7

    // AR guides
    private var originNode: SCNNode?
    private var normalFrameCount: Int = 0
    private let normalFrameThreshold: Int = 10

    override func viewDidLoad() {
        super.viewDidLoad()

        scnView = ARSCNView(frame: view.bounds)
        scnView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scnView.debugOptions.insert(.showFeaturePoints)
        view.addSubview(scnView)

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

        // Start Bonjour advertising + browsing instead of connecting immediately
        let deviceModel = Self.deviceModelIdentifier()
        BonjourManager.shared.startAll(sessionId: sessionId, deviceModel: deviceModel)

        self.publishPose = false  // Wait for connection via discovered server or manual connect
        scnView.session.delegate = self
        let configuration = ARWorldTrackingConfiguration()
        scnView.session.run(configuration)
        setupARGuides()
    }

    // MARK: - AR Visual Guides

    func setupARGuides() {
        originNode?.removeFromParentNode()

        let origin = SCNNode()
        let axisLength: CGFloat = 0.15
        let axisThick: CGFloat = 0.004

        func unlitMaterial(_ color: UIColor) -> SCNMaterial {
            let mat = SCNMaterial()
            mat.diffuse.contents = color
            mat.lightingModel = .constant
            return mat
        }

        // X — red
        let xAxis = SCNNode(geometry: SCNBox(width: axisLength, height: axisThick, length: axisThick, chamferRadius: 0))
        xAxis.geometry?.firstMaterial = unlitMaterial(.red)
        xAxis.position = SCNVector3(axisLength / 2, 0, 0)
        origin.addChildNode(xAxis)

        // Y — green
        let yAxis = SCNNode(geometry: SCNBox(width: axisThick, height: axisLength, length: axisThick, chamferRadius: 0))
        yAxis.geometry?.firstMaterial = unlitMaterial(.green)
        yAxis.position = SCNVector3(0, axisLength / 2, 0)
        origin.addChildNode(yAxis)

        // Z — blue
        let zAxis = SCNNode(geometry: SCNBox(width: axisThick, height: axisThick, length: axisLength, chamferRadius: 0))
        zAxis.geometry?.firstMaterial = unlitMaterial(.blue)
        zAxis.position = SCNVector3(0, 0, axisLength / 2)
        origin.addChildNode(zAxis)

        // Origin sphere
        let sphere = SCNNode(geometry: SCNSphere(radius: 0.008))
        sphere.geometry?.firstMaterial = unlitMaterial(.white)
        origin.addChildNode(sphere)

        scnView.scene.rootNode.addChildNode(origin)
        originNode = origin
    }

    // MARK: - Action Stream

    private var cancellables: Set<AnyCancellable> = []
    private var publishPose: Bool = false

    func subscribeToActionStream() {

        ARManager.shared
            .actionStream
            .sink { [weak self] action in
                switch action {
                    case .resetOrigin:
                        self?.hasSentMetadata = false
                        self?.sessionId = UUID().uuidString
                        let configuration = ARWorldTrackingConfiguration()
                        self?.scnView.session.run(configuration, options: .resetTracking)
                        self?.setupARGuides()
                    case .disconnect:
                        self?.publishPose = false
                        self?.networkClient.disconnect()
                    case .connectToEndpoint(let endpoint):
                        guard let self = self else { return }
                        self.publishPose = false
                        self.networkClient.disconnect()
                        self.hasSentMetadata = false
                        self.sessionId = UUID().uuidString
                        print("Connecting to discovered endpoint: \(endpoint)")
                        self.networkClient.connect(endpoint: endpoint)
                        self.publishPose = true
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
        scnView.session.pause()
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
