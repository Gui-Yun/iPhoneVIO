# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**iOS ARKit app that streams Visual Inertial Odometry (VIO) pose data via Socket.IO to a Python server.**

## Tech Stack

- **iOS**: Swift 5.0, SwiftUI, ARKit, RealityKit, Combine
- **Minimum iOS**: 17.4 (deployment target in project.pbxproj, though Podfile specifies 17.2)
- **Dependencies**: CocoaPods with Socket.IO-Client-Swift ~> 16.1.0 (brings in Starscream)
- **Server**: Python with python-socketio, eventlet, numpy

## Project Structure

```
iPhoneVIO/
├── iPhoneVIO/               # iOS app source
│   ├── ContentView.swift    # SwiftUI UI with IP/port config
│   ├── ARSessionManager.swift  # ViewController: ARSession + ARSessionDelegate
│   ├── SocketClient.swift   # Socket.IO client for data streaming
│   ├── ARManager.swift      # Singleton with action stream (Combine)
│   └── ARAction.swift       # Action enum for IP/port updates
├── socketio_server.py       # Python server (port 5555)
├── Podfile                  # CocoaPods dependencies
└── iPhoneVIO.xcworkspace    # MUST use this (not .xcodeproj)
```

## Data Flow

```
ARKit frame update → ViewController.session(_:didUpdate:)
  → DataPacket(4x4 transform matrix + timestamp)
  → toBytes() (column-major float[16] + double timestamp)
  → base64 encode
  → Socket.IO emit("update", data)
  → Python server decodes (transposes matrix to row-major)
```

**Important**: Swift stores simd_float4x4 in column-major order. Python server transposes to row-major.

## Essential Commands

### iOS App
```bash
# Install dependencies (required after git clone)
pod install

# Open project (MUST use workspace due to CocoaPods)
open iPhoneVIO.xcworkspace

# Build from command line
xcodebuild -workspace iPhoneVIO.xcworkspace -scheme iPhoneVIO -sdk iphoneos build

# Run tests
xcodebuild -workspace iPhoneVIO.xcworkspace -scheme iPhoneVIO test
```

### Python Server
```bash
# Setup venv (Python 3.11 used in project)
python3 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install python-socketio eventlet numpy

# Run server (listens on 0.0.0.0:5555)
python socketio_server.py
```

## Critical Constraints

1. **No Simulator Support**: ARKit requires a real iOS device
2. **Always Use .xcworkspace**: Due to CocoaPods integration
3. **Camera Permissions**: App requires camera access for ARKit
4. **Network**: iOS device and Python server must be on same network
5. **Default Server**: App defaults to 192.168.123.18:5555 (configurable in UI)

## Architecture Notes

- **ViewController** (ARSessionManager.swift) is both UIViewController and ARSessionDelegate
- **ARManager.shared** provides a Combine-based action stream for IP/port updates
- **SocketClient** manages connection lifecycle and data serialization
- **ContentView** provides SwiftUI UI with ARViewContainer (UIViewControllerRepresentable)

## Verification

After changes to iOS app:
1. Build succeeds in Xcode
2. App runs on physical device
3. ARKit session starts (camera view visible)
4. Socket.IO connects to Python server
5. Server logs show incoming pose data with FPS

After changes to Python server:
1. Server starts on port 5555
2. Accepts Socket.IO connections
3. Decodes base64 data successfully
4. Prints translation and FPS
