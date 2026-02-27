import SceneKit
import SceneKit.ModelIO
import ModelIO

class RobotRenderer {
    let rootNode: SCNNode
    private var linkNodes: [SCNNode] = []
    private let feasibleMaterial: SCNMaterial
    private let infeasibleMaterial: SCNMaterial
    private var meshScale: Float = 1.0

    init(model: RobotKinematics) {
        rootNode = SCNNode()
        rootNode.name = "robotGhost"
        rootNode.isHidden = true

        feasibleMaterial = RobotRenderer.makeMaterial(
            color: UIColor(red: 0.7, green: 1.0, blue: 0.7, alpha: 0.5)
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
    }

    func updateTransforms(_ fkResult: FKResult) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        for (i, transform) in fkResult.linkTransforms.enumerated() where i < linkNodes.count {
            linkNodes[i].simdTransform = transform
        }
        SCNTransaction.commit()
    }

    func setFeasibility(_ feasible: Bool) {
        let material = feasible ? feasibleMaterial : infeasibleMaterial
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
