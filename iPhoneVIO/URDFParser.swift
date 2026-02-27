import Foundation
import simd

class URDFParser: NSObject, XMLParserDelegate {
    private var robotName = ""
    private var links: [LinkDef] = []
    private var joints: [JointDef] = []

    // Current parsing state
    private var elementStack: [String] = []
    private var currentLinkName: String?
    private var currentMeshFilename: String?
    private var currentVisualOriginXYZ = SIMD3<Float>.zero
    private var currentVisualOriginRPY = SIMD3<Float>.zero
    private var inVisual = false

    private var currentJointName: String?
    private var currentJointType: JointType = .revolute
    private var currentParentLink: String?
    private var currentChildLink: String?
    private var currentJointOriginXYZ = SIMD3<Float>.zero
    private var currentJointOriginRPY = SIMD3<Float>.zero
    private var currentAxis = SIMD3<Float>(0, 0, 1)
    private var currentLimitLower: Float = 0
    private var currentLimitUpper: Float = 0
    private var currentLimitVelocity: Float = 0

    func parse(data: Data) -> RobotKinematics? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return nil }
        return RobotKinematics(name: robotName, links: links, joints: joints)
    }

    func parse(url: URL) -> RobotKinematics? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data: data)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String]) {
        elementStack.append(elementName)

        switch elementName {
        case "robot":
            robotName = attributeDict["name"] ?? ""

        case "link":
            currentLinkName = attributeDict["name"]
            currentMeshFilename = nil
            currentVisualOriginXYZ = .zero
            currentVisualOriginRPY = .zero
            inVisual = false

        case "visual":
            if currentLinkName != nil {
                inVisual = true
            }

        case "origin":
            let xyz = parseVec3(attributeDict["xyz"])
            let rpy = parseVec3(attributeDict["rpy"])
            if currentJointName != nil && parentElement() == "joint" {
                currentJointOriginXYZ = xyz
                currentJointOriginRPY = rpy
            } else if inVisual && parentElement() == "visual" {
                currentVisualOriginXYZ = xyz
                currentVisualOriginRPY = rpy
            }

        case "mesh":
            if inVisual, let filename = attributeDict["filename"] {
                currentMeshFilename = stripPackagePrefix(filename)
            }

        case "joint":
            currentJointName = attributeDict["name"]
            let typeStr = attributeDict["type"] ?? "revolute"
            currentJointType = JointType(rawValue: typeStr) ?? .revolute
            currentParentLink = nil
            currentChildLink = nil
            currentJointOriginXYZ = .zero
            currentJointOriginRPY = .zero
            currentAxis = SIMD3<Float>(0, 0, 1)
            currentLimitLower = 0
            currentLimitUpper = 0
            currentLimitVelocity = 0

        case "parent":
            if currentJointName != nil {
                currentParentLink = attributeDict["link"]
            }

        case "child":
            if currentJointName != nil {
                currentChildLink = attributeDict["link"]
            }

        case "axis":
            if currentJointName != nil {
                currentAxis = parseVec3(attributeDict["xyz"])
            }

        case "limit":
            if currentJointName != nil {
                currentLimitLower = Float(attributeDict["lower"] ?? "0") ?? 0
                currentLimitUpper = Float(attributeDict["upper"] ?? "0") ?? 0
                currentLimitVelocity = Float(attributeDict["velocity"] ?? "0") ?? 0
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "visual":
            inVisual = false

        case "link":
            if let name = currentLinkName {
                let visualTransform = makeTransform(xyz: currentVisualOriginXYZ, rpy: currentVisualOriginRPY)
                links.append(LinkDef(name: name, meshFilename: currentMeshFilename, visualOriginTransform: visualTransform))
            }
            currentLinkName = nil

        case "joint":
            if let name = currentJointName,
               let parent = currentParentLink,
               let child = currentChildLink {
                joints.append(JointDef(
                    name: name,
                    type: currentJointType,
                    parentLink: parent,
                    childLink: child,
                    originXYZ: currentJointOriginXYZ,
                    originRPY: currentJointOriginRPY,
                    axis: currentAxis,
                    posLower: currentLimitLower,
                    posUpper: currentLimitUpper,
                    velLimit: currentLimitVelocity
                ))
            }
            currentJointName = nil

        default:
            break
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
    }

    // MARK: - Helpers

    private func parentElement() -> String? {
        guard elementStack.count >= 2 else { return nil }
        return elementStack[elementStack.count - 2]
    }

    private func parseVec3(_ str: String?) -> SIMD3<Float> {
        guard let str = str else { return .zero }
        let parts = str.split(separator: " ").compactMap { Float($0) }
        guard parts.count >= 3 else { return .zero }
        return SIMD3<Float>(parts[0], parts[1], parts[2])
    }

    private func stripPackagePrefix(_ filename: String) -> String {
        // Strip "package://rm_description/meshes/RM75/" or similar
        if let range = filename.range(of: "meshes/RM75/") {
            return String(filename[range.upperBound...])
        }
        // Fallback: just the last path component
        return (filename as NSString).lastPathComponent
    }
}
