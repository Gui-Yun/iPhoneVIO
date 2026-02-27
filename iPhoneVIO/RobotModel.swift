import simd

enum JointType: String {
    case revolute
    case prismatic
    case fixed
}

struct JointDef {
    let name: String
    let type: JointType
    let parentLink: String
    let childLink: String
    let originXYZ: SIMD3<Float>
    let originRPY: SIMD3<Float>
    let axis: SIMD3<Float>
    let posLower: Float
    let posUpper: Float
    let velLimit: Float

    var originTransform: simd_float4x4 {
        makeTransform(xyz: originXYZ, rpy: originRPY)
    }
}

struct LinkDef {
    let name: String
    let meshFilename: String?
    let visualOriginTransform: simd_float4x4
}

struct RobotKinematics {
    let name: String
    var links: [LinkDef]
    var joints: [JointDef]
    var dof: Int { joints.count }
}

func makeTransform(xyz: SIMD3<Float>, rpy: SIMD3<Float>) -> simd_float4x4 {
    let cr = cos(rpy.x); let sr = sin(rpy.x)
    let cp = cos(rpy.y); let sp = sin(rpy.y)
    let cy = cos(rpy.z); let sy = sin(rpy.z)

    // ZYX Euler: Rz(yaw) * Ry(pitch) * Rx(roll)
    let r00 = cy * cp
    let r01 = cy * sp * sr - sy * cr
    let r02 = cy * sp * cr + sy * sr
    let r10 = sy * cp
    let r11 = sy * sp * sr + cy * cr
    let r12 = sy * sp * cr - cy * sr
    let r20 = -sp
    let r21 = cp * sr
    let r22 = cp * cr

    return simd_float4x4(columns: (
        SIMD4<Float>(r00, r10, r20, 0),
        SIMD4<Float>(r01, r11, r21, 0),
        SIMD4<Float>(r02, r12, r22, 0),
        SIMD4<Float>(xyz.x, xyz.y, xyz.z, 1)
    ))
}

func rotationAboutAxis(_ axis: SIMD3<Float>, angle: Float) -> simd_float4x4 {
    let c = cos(angle)
    let s = sin(angle)
    let t = 1 - c
    let x = axis.x, y = axis.y, z = axis.z

    return simd_float4x4(columns: (
        SIMD4<Float>(t*x*x + c,   t*x*y + z*s, t*x*z - y*s, 0),
        SIMD4<Float>(t*x*y - z*s, t*y*y + c,   t*y*z + x*s, 0),
        SIMD4<Float>(t*x*z + y*s, t*y*z - x*s, t*z*z + c,   0),
        SIMD4<Float>(0, 0, 0, 1)
    ))
}
