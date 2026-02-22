//
//  OrientationCubeView.swift
//  iPhoneVIO
//

import SwiftUI
import SceneKit
import simd

struct OrientationCubeView: UIViewRepresentable {
    var cameraTransform: simd_float4x4

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = .clear
        scnView.allowsCameraControl = false
        scnView.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        scene.background.contents = UIColor.clear

        let axisLength: CGFloat = 0.55
        let axisRadius: CGFloat = 0.03
        let coneHeight: CGFloat = 0.12
        let coneRadius: CGFloat = 0.06

        func makeAxis(color: UIColor, direction: SCNVector3) -> SCNNode {
            let axisNode = SCNNode()

            let cylinder = SCNCylinder(radius: axisRadius, height: axisLength)
            let mat = SCNMaterial()
            mat.diffuse.contents = color
            mat.lightingModel = .constant
            cylinder.materials = [mat]
            let cylNode = SCNNode(geometry: cylinder)
            cylNode.position = SCNVector3(0, Float(axisLength / 2), 0)
            axisNode.addChildNode(cylNode)

            let cone = SCNCone(topRadius: 0, bottomRadius: coneRadius, height: coneHeight)
            let coneMat = SCNMaterial()
            coneMat.diffuse.contents = color
            coneMat.lightingModel = .constant
            cone.materials = [coneMat]
            let coneNode = SCNNode(geometry: cone)
            coneNode.position = SCNVector3(0, Float(axisLength + coneHeight / 2), 0)
            axisNode.addChildNode(coneNode)

            if direction.x > 0 {
                axisNode.eulerAngles = SCNVector3(0, 0, -Float.pi / 2)
            } else if direction.z > 0 {
                axisNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            }

            return axisNode
        }

        func makeLabel(_ text: String, color: UIColor, position: SCNVector3) -> SCNNode {
            let textGeo = SCNText(string: text, extrusionDepth: 0.01)
            textGeo.font = UIFont.boldSystemFont(ofSize: 0.2)
            let mat = SCNMaterial()
            mat.diffuse.contents = color
            mat.lightingModel = .constant
            textGeo.materials = [mat]
            let node = SCNNode(geometry: textGeo)
            let (min, max) = textGeo.boundingBox
            let dx = (max.x - min.x) / 2
            let dy = (max.y - min.y) / 2
            node.pivot = SCNMatrix4MakeTranslation(dx + min.x, dy + min.y, 0)
            node.position = position
            let billboardConstraint = SCNBillboardConstraint()
            node.constraints = [billboardConstraint]
            return node
        }

        // --- Static world axes (direct children of scene root, never rotated) ---
        let axesNode = SCNNode()
        axesNode.name = "worldAxes"
        axesNode.addChildNode(makeAxis(color: .red, direction: SCNVector3(1, 0, 0)))
        axesNode.addChildNode(makeAxis(color: .green, direction: SCNVector3(0, 1, 0)))
        axesNode.addChildNode(makeAxis(color: .blue, direction: SCNVector3(0, 0, 1)))

        let labelOffset: Float = Float(axisLength + coneHeight) + 0.1
        axesNode.addChildNode(makeLabel("X", color: .red, position: SCNVector3(labelOffset, 0, 0)))
        axesNode.addChildNode(makeLabel("Y", color: .green, position: SCNVector3(0, labelOffset, 0)))
        axesNode.addChildNode(makeLabel("Z", color: .blue, position: SCNVector3(0, 0, labelOffset)))

        // Origin sphere
        let sphere = SCNSphere(radius: 0.06)
        let sphereMat = SCNMaterial()
        sphereMat.diffuse.contents = UIColor.white
        sphereMat.lightingModel = .constant
        sphere.materials = [sphereMat]
        axesNode.addChildNode(SCNNode(geometry: sphere))

        scene.rootNode.addChildNode(axesNode)

        // --- Rotating cube (follows device orientation) ---
        let cubeNode = SCNNode()
        cubeNode.name = "deviceCube"

        // Give each face a different color so orientation is obvious
        let cube = SCNBox(width: 0.5, height: 0.5, length: 0.5, chamferRadius: 0.02)
        let colors: [UIColor] = [
            UIColor.red.withAlphaComponent(0.3),    // +X right
            UIColor.red.withAlphaComponent(0.15),   // -X left
            UIColor.green.withAlphaComponent(0.3),   // +Y top
            UIColor.green.withAlphaComponent(0.15),  // -Y bottom
            UIColor.blue.withAlphaComponent(0.3),    // +Z front
            UIColor.blue.withAlphaComponent(0.15),   // -Z back
        ]
        cube.materials = colors.map { c in
            let m = SCNMaterial()
            m.diffuse.contents = c
            m.lightingModel = .constant
            return m
        }
        cubeNode.geometry = cube
        scene.rootNode.addChildNode(cubeNode)

        // Camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.usesOrthographicProjection = true
        cameraNode.camera?.orthographicScale = 1.2
        cameraNode.position = SCNVector3(0, 0, 3)
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)

        // Ambient light
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.color = UIColor(white: 0.6, alpha: 1)
        scene.rootNode.addChildNode(ambientLight)

        scnView.scene = scene
        scnView.pointOfView = cameraNode

        return scnView
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        guard let cubeNode = scnView.scene?.rootNode.childNode(withName: "deviceCube", recursively: false) else { return }

        // Extract rotation only (device orientation in world frame)
        var rotationMatrix = cameraTransform
        rotationMatrix.columns.3 = simd_float4(0, 0, 0, 1)

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        cubeNode.simdTransform = rotationMatrix
        SCNTransaction.commit()
    }
}
