import SceneKit
import SceneKit.ModelIO
import ModelIO

class RobotRenderer {
    let rootNode: SCNNode
    private var linkNodes: [SCNNode] = []
    private let feasibleMaterial: SCNMaterial
    private let warningMaterial: SCNMaterial
    private let infeasibleMaterial: SCNMaterial
    private var meshScale: Float = 1.0

    init(model: RobotKinematics) {
        rootNode = SCNNode()
        rootNode.name = "robotGhost"
        rootNode.isHidden = true

        feasibleMaterial = RobotRenderer.makeMaterial(
            color: UIColor(red: 0.7, green: 1.0, blue: 0.7, alpha: 0.5)
        )
        warningMaterial = RobotRenderer.makeMaterial(
            color: UIColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 0.5)
        )
        infeasibleMaterial = RobotRenderer.makeMaterial(
            color: UIColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.5)
        )

        loadMeshes(model: model)
    }

    private static func makeMaterial(color: UIColor) -> SCNMaterial {
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.lightingModel = .physicallyBased
        mat.isDoubleSided = true
        mat.transparencyMode = .dualLayer
        mat.writesToDepthBuffer = true
        mat.readsFromDepthBuffer = true
        return mat
    }

    private func loadMeshes(model: RobotKinematics) {
        var scaleDetected = false

        for link in model.links {
            let node = SCNNode()
            node.name = link.name

            if let meshFilename = link.meshFilename,
               let url = Bundle.main.url(forResource: meshFilename.replacingOccurrences(of: ".STL", with: ""),
                                         withExtension: "STL",
                                         subdirectory: "RM75") {
                let asset = MDLAsset(url: url)
                if let mdlMesh = asset.object(at: 0) as? MDLMesh {
                    // Detect mm vs m scale from first mesh
                    if !scaleDetected {
                        let extent = mdlMesh.boundingBox.maxBounds - mdlMesh.boundingBox.minBounds
                        let maxDim = max(extent.x, max(extent.y, extent.z))
                        if maxDim > 100 {
                            meshScale = 0.001
                        }
                        scaleDetected = true
                    }

                    let meshNode = SCNNode(mdlObject: mdlMesh)
                    meshNode.geometry?.materials = [feasibleMaterial]
                    // Transfer geometry to our node
                    node.geometry = meshNode.geometry

                    if meshScale != 1.0 {
                        node.scale = SCNVector3(meshScale, meshScale, meshScale)
                    }
                }
            }

            // Apply visual origin offset
            let visualNode = SCNNode()
            visualNode.simdTransform = link.visualOriginTransform
            visualNode.addChildNode(node)

            let wrapperNode = SCNNode()
            wrapperNode.name = "wrapper_\(link.name)"
            wrapperNode.addChildNode(visualNode)

            linkNodes.append(wrapperNode)
            rootNode.addChildNode(wrapperNode)
        }

        // Attach gripper to Link7 wrapper
        if let link7Wrapper = linkNodes.last {
            loadGripper(parentNode: link7Wrapper)
        }
    }

    // MARK: - Gripper

    private func loadGripper(parentNode: SCNNode) {
        // Fixed joint: attach gripper base to Link7 with rpy="0 π/2 0"
        let gripperAttach = SCNNode()
        gripperAttach.name = "gripper_attach"
        gripperAttach.simdTransform = makeTransform(
            xyz: SIMD3<Float>(0, 0, 0),
            rpy: SIMD3<Float>(0, -.pi / 2, 0)
        )

        // Gripper base link
        let gripperBase = loadGripperMesh(filename: "base_link", extension: "stl")
        gripperBase.name = "gripper_base"
        gripperAttach.addChildNode(gripperBase)

        // Left finger: joint origin xyz="0.062457 -0.07246 0.029826"
        //              visual origin xyz="-0.062457 0.07246 -0.029826"
        let leftJointNode = SCNNode()
        leftJointNode.name = "gripper_left_joint"
        leftJointNode.simdTransform = makeTransform(
            xyz: SIMD3<Float>(0.062457, -0.07246, 0.029826),
            rpy: .zero
        )
        let leftVisualNode = SCNNode()
        leftVisualNode.simdTransform = makeTransform(
            xyz: SIMD3<Float>(-0.062457, 0.07246, -0.029826),
            rpy: .zero
        )
        let leftMesh = loadGripperMesh(filename: "gripper_left_1_1", extension: "stl")
        leftVisualNode.addChildNode(leftMesh)
        leftJointNode.addChildNode(leftVisualNode)
        gripperAttach.addChildNode(leftJointNode)

        // Right finger: joint origin xyz="0.062457 0.072822 -0.028386"
        //               visual origin xyz="-0.062457 -0.072822 0.028386"
        let rightJointNode = SCNNode()
        rightJointNode.name = "gripper_right_joint"
        rightJointNode.simdTransform = makeTransform(
            xyz: SIMD3<Float>(0.062457, 0.072822, -0.028386),
            rpy: .zero
        )
        let rightVisualNode = SCNNode()
        rightVisualNode.simdTransform = makeTransform(
            xyz: SIMD3<Float>(-0.062457, -0.072822, 0.028386),
            rpy: .zero
        )
        let rightMesh = loadGripperMesh(filename: "gripper_right_1_1", extension: "stl")
        rightVisualNode.addChildNode(rightMesh)
        rightJointNode.addChildNode(rightVisualNode)
        gripperAttach.addChildNode(rightJointNode)

        parentNode.addChildNode(gripperAttach)
    }

    private func loadGripperMesh(filename: String, extension ext: String) -> SCNNode {
        let node = SCNNode()
        guard let url = Bundle.main.url(forResource: filename,
                                        withExtension: ext,
                                        subdirectory: "gripper") else {
            print("[RobotRenderer] Gripper mesh not found: \(filename).\(ext)")
            return node
        }

        let asset = MDLAsset(url: url)
        if let mdlMesh = asset.object(at: 0) as? MDLMesh {
            let meshNode = SCNNode(mdlObject: mdlMesh)
            meshNode.geometry?.materials = [feasibleMaterial]
            node.geometry = meshNode.geometry
            // Gripper meshes are in mm, scale to meters
            node.scale = SCNVector3(0.001, 0.001, 0.001)
        }
        return node
    }

    func updateTransforms(_ fkResult: FKResult) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        for (i, transform) in fkResult.linkTransforms.enumerated() where i < linkNodes.count {
            linkNodes[i].simdTransform = transform
        }
        SCNTransaction.commit()
    }

    func setFeasibilityState(_ state: FeasibilityState) {
        let material: SCNMaterial
        switch state {
        case .feasible:   material = feasibleMaterial
        case .warning:    material = warningMaterial
        case .infeasible: material = infeasibleMaterial
        }
        for node in linkNodes {
            node.enumerateChildNodes { child, _ in
                child.geometry?.materials = [material]
            }
        }
    }

    func setBaseTransform(_ transform: simd_float4x4) {
        rootNode.simdTransform = transform
    }

    func show() {
        rootNode.isHidden = false
    }

    func hide() {
        rootNode.isHidden = true
    }
}
