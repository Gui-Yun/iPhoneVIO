# iPhoneVIO + FeasibleCap

iOS ARKit app that streams VIO pose data (pose + JPEG) via TCP to a Python/Rust server, and overlays a real-time "ghost arm" AR visualization for robot teleoperation feasibility checking.

## Tech Stack

- **iOS**: Swift 5.0, SwiftUI, ARKit, ARSCNView (SceneKit), Model I/O, Accelerate, CoreHaptics, Network.framework
- **Minimum iOS**: 17.2 (Podfile) / 17.4 (project.pbxproj deployment target)
- **Dependencies**: CocoaPods present but currently no pods — Network.framework is built-in
- **Server**: Python with python-socketio/eventlet (legacy `socketio_server.py`); primary server is rapid_driver (external Rust/axum binary)

## Project Structure

```
iPhoneVIO/
├── iPhoneVIO/                  # iOS app source
│   ├── ContentView.swift       # SwiftUI root: AR view + all overlay panels
│   ├── ARSessionManager.swift  # UIViewController: ARSCNView, ARSessionDelegate, FeasibleCap orchestration
│   ├── ARManager.swift         # Singleton Combine action stream
│   ├── ARAction.swift          # Action enum (connect, disconnect, FeasibleCap actions)
│   ├── NetworkClient.swift     # Raw TCP client: binary frame protocol (8-byte header + payload)
│   ├── BonjourManager.swift    # mDNS: advertises _iphonevio._tcp, discovers _vioserver._tcp + _rapiddriver._tcp
│   ├── RecordingController.swift  # HTTP client for rapid_driver recording/replay/device control API
│   ├── DataManagementController.swift  # HTTP client for recordings CRUD + replay
│   ├── DataManagementView.swift  # SwiftUI: MCAP file browser, delete, replay
│   ├── HapticManager.swift     # CoreHaptics: continuous warning + transient pulse
│   ├── OrientationCubeView.swift  # Live SCNView orientation indicator (top-right HUD)
│   ├── RobotModel.swift        # Value types: JointDef, LinkDef, RobotKinematics, makeTransform()
│   ├── URDFParser.swift        # SAX XML parser → RobotKinematics
│   ├── IKSolver.swift          # Damped Least-Squares IK + FK (7-DoF RM75, uses Accelerate sgesv_)
│   ├── RobotRenderer.swift     # SceneKit ghost arm: STL mesh loading, FK transform updates, feasibility coloring
│   ├── FeasibilityChecker.swift  # Per-frame: IK convergence + joint limits + velocity limits
│   └── Resources/
│       ├── RM75/               # RM75 robot: rm_75.urdf + link1-7.STL meshes
│       └── gripper/            # Gripper: base_link.stl, gripper_left_1_1.stl, gripper_right_1_1.stl
├── iPhoneVIOTests/             # Unit tests (currently out of sync with model fields — fix before relying on them)
├── socketio_server.py          # Legacy Python server (Socket.IO, port 5555)
├── docs/
│   ├── feasiblecap_feature_gap.md   # Feature roadmap vs paper (Chinese)
│   └── recording_management_api.md  # rapid_driver HTTP API spec (Chinese)
├── Podfile
└── iPhoneVIO.xcworkspace       # MUST use this (not .xcodeproj)
```

## Key Subsystems

### Data Streaming
ARKit frame → `ViewController.session(_:didUpdate:)` → JPEG compress (background queue) → `FramePacket.toBytes()` → `NetworkClient.sendFrame()` → TCP binary stream.

Binary frame format: `[8B header: 4B payload_len + 1B msg_type + 3B reserved] [4B jpeg_size] [64B transform column-major float32×16] [8B device_ts] [8B wall_clock] [jpeg_data]`.

Swift `simd_float4x4` is column-major. Python server transposes to row-major on decode.

### Network Discovery
`BonjourManager` advertises `_iphonevio._tcp` (so rapid_driver finds the phone) and browses for `_vioserver._tcp` (auto-connect for data streaming) and `_rapiddriver._tcp` (HTTP control API for recording). Auto-reconnect on disconnect is handled in `ContentView`.

### FeasibleCap (Ghost Arm)
Lazy-initialized on first `.startBasePlacement` action. Per-frame pipeline (60 Hz, only when clutch engaged):
1. `IKSolver.solve()` — DLS IK with warm start, Accelerate `sgesv_` for the 6×6 linear solve
2. `RobotRenderer.updateTransforms()` — apply FK link transforms to SceneKit nodes
3. `FeasibilityChecker.evaluate()` — IK convergence + joint position limits + velocity limits
4. `HapticManager` — continuous haptic on infeasible, transient pulse on state transition

Ghost arm is green (feasible) or red (infeasible). Robot is RM75 (7-DoF) with a fixed gripper on Link7.

### Recording Management
`RecordingController` polls `rapid_driver` HTTP API every 2 s for device ready status. Recording start/stop and replay are triggered via POST. See `docs/recording_management_api.md` for the full API spec.

## Essential Commands

```bash
# Install CocoaPods (required after git clone even if no pods are active)
pod install

# Open project — MUST use workspace
open iPhoneVIO.xcworkspace

# Build for device
xcodebuild -workspace iPhoneVIO.xcworkspace -scheme iPhoneVIO -sdk iphoneos build

# Run unit tests (note: some tests are out of sync with current model fields)
xcodebuild -workspace iPhoneVIO.xcworkspace -scheme iPhoneVIO test

# Legacy Python server (Socket.IO, port 5555)
python3 -m venv .venv && source .venv/bin/activate
pip install python-socketio eventlet numpy
python socketio_server.py
```

## Critical Constraints

- **No simulator**: ARKit requires a real iOS device
- **Always use `.xcworkspace`**: CocoaPods integration
- **Landscape only**: `ViewController` locks to landscape
- **FeasibleCap requires horizontal surface**: base placement uses ARKit plane detection raycast
- **STL scale detection**: `RobotRenderer` auto-detects mm vs m from bounding box (max dimension >100 → scale ×0.001). Gripper meshes are always treated as mm.
- **URDF parsing**: uses `Foundation.XMLParser` (SAX). `XMLDocument` is not available on iOS.

## Architecture Notes

- `ViewController` (ARSessionManager.swift) owns `ARSCNView`, the AR session, and all FeasibleCap state
- `ARManager.shared` is a Combine `PassthroughSubject` action bus; UI sends actions, `ViewController` reacts
- FeasibleCap components (`IKSolver`, `RobotRenderer`, `FeasibilityChecker`, `HapticManager`) are lazily created on first base placement — no startup cost when the feature is unused
- `RobotRenderer.rootNode` is added directly to `scnView.scene.rootNode`
- `camToTCPOffset` (`simd_float4x4`) captures the camera→TCP extrinsic; updated via `.calibrateCamToTCP` action
- Protocol versioning: `NetworkClient` message types are `0x00` (sessionMetadata JSON) and `0x01` (frameData binary). A future `0x02` type for feasibility metadata is planned — see `docs/feasiblecap_feature_gap.md` Feature 10 for the wire format

## Verification

After iOS changes:
1. Build succeeds (no simulator — requires a physical device target in Xcode)
2. FeasibleCap: base placement finds a horizontal surface, ghost arm appears, clutch toggle works, haptic fires on feasibility state change
3. Data stream: mDNS discovers server, green status dot, server logs show incoming frames

After Python server changes:
1. `python socketio_server.py` starts on port 5555
2. Server logs show translation and FPS on each received frame
