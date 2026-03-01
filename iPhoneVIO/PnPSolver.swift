import simd
import Accelerate

/// Solves Perspective-n-Point for planar markers using homography decomposition (IPPE).
/// Specialized for ArUco-style square markers on the Z=0 plane.
struct PnPSolver {

    /// Solve for the camera-relative pose of a planar marker.
    /// - Parameters:
    ///   - imagePoints: 4 corner points in pixel coordinates (TL, TR, BR, BL)
    ///   - markerSize: physical marker side length in meters
    ///   - intrinsics: 3×3 camera intrinsics matrix (fx, fy, cx, cy)
    /// - Returns: 4×4 transform from marker frame to camera frame, or nil on failure
    func solve(
        imagePoints: [SIMD2<Float>],
        markerSize: Float,
        intrinsics: simd_float3x3
    ) -> simd_float4x4? {
        guard imagePoints.count == 4 else { return nil }

        let half = markerSize / 2.0
        // Marker corners in marker frame (Z=0 plane), matching TL/TR/BR/BL order
        let objectPoints: [SIMD2<Float>] = [
            SIMD2<Float>(-half,  half),  // TL
            SIMD2<Float>( half,  half),  // TR
            SIMD2<Float>( half, -half),  // BR
            SIMD2<Float>(-half, -half)   // BL
        ]

        // 1. Normalize image points: p_norm = K^{-1} * [u, v, 1]^T
        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]

        let normalizedPoints = imagePoints.map { p -> SIMD2<Float> in
            SIMD2<Float>((p.x - cx) / fx, (p.y - cy) / fy)
        }

        // 2. Compute homography: normalizedPoints = H * objectPoints (on Z=0 plane)
        guard let H = computeHomography(from: objectPoints, to: normalizedPoints) else {
            return nil
        }

        // 3. Decompose H = [r1 | r2 | t] (up to scale)
        let h0 = SIMD3<Float>(H[0], H[3], H[6])  // column 0
        let h1 = SIMD3<Float>(H[1], H[4], H[7])  // column 1
        let h2 = SIMD3<Float>(H[2], H[5], H[8])  // column 2

        let norm0 = simd_length(h0)
        let norm1 = simd_length(h1)
        guard norm0 > 1e-8 && norm1 > 1e-8 else { return nil }

        let scale = (norm0 + norm1) / 2.0

        var r1 = h0 / norm0
        var r2 = h1 / norm1
        var r3 = simd_cross(r1, r2)
        let t = h2 / scale

        // Translation must have positive Z (marker in front of camera)
        if t.z < 0 {
            r1 = -r1
            r2 = -r2
            r3 = simd_cross(r1, r2)
            // t is also negated implicitly by the sign flip
            let tFixed = -t
            return buildPose(r1: r1, r2: r2, r3: r3, t: tFixed)
        }

        // 4. Orthogonalize rotation using SVD
        return buildPose(r1: r1, r2: r2, r3: r3, t: t)
    }

    // MARK: - Homography (DLT, exactly 4 point pairs)

    /// Computes 3×3 homography H such that dst ~ H * [src, 1].
    /// Returns H as a row-major 9-element array, or nil on failure.
    private func computeHomography(
        from src: [SIMD2<Float>],
        to dst: [SIMD2<Float>]
    ) -> [Float]? {
        guard src.count == 4 && dst.count == 4 else { return nil }

        // Set h33 = 1, solve 8×8 linear system
        // For each (Sx,Sy) → (Dx,Dy):
        //   h11*Sx + h12*Sy + h13 - h31*Sx*Dx - h32*Sy*Dx = Dx
        //   h21*Sx + h22*Sy + h23 - h31*Sx*Dy - h32*Sy*Dy = Dy

        var M = [Float](repeating: 0, count: 64) // 8×8 column-major
        var b = [Float](repeating: 0, count: 8)

        for i in 0..<4 {
            let sx = src[i].x, sy = src[i].y
            let dx = dst[i].x, dy = dst[i].y
            let r0 = i * 2, r1 = r0 + 1

            M[r0 + 0 * 8] = sx;  M[r0 + 1 * 8] = sy;  M[r0 + 2 * 8] = 1
            M[r0 + 3 * 8] = 0;   M[r0 + 4 * 8] = 0;   M[r0 + 5 * 8] = 0
            M[r0 + 6 * 8] = -sx * dx; M[r0 + 7 * 8] = -sy * dx
            b[r0] = dx

            M[r1 + 0 * 8] = 0;   M[r1 + 1 * 8] = 0;   M[r1 + 2 * 8] = 0
            M[r1 + 3 * 8] = sx;  M[r1 + 4 * 8] = sy;  M[r1 + 5 * 8] = 1
            M[r1 + 6 * 8] = -sx * dy; M[r1 + 7 * 8] = -sy * dy
            b[r1] = dy
        }

        var n: Int32 = 8, nrhs: Int32 = 1, lda: Int32 = 8
        var ipiv = [Int32](repeating: 0, count: 8)
        var ldb: Int32 = 8, info: Int32 = 0
        sgesv_(&n, &nrhs, &M, &lda, &ipiv, &b, &ldb, &info)
        guard info == 0 else { return nil }

        // H in row-major: [h11,h12,h13, h21,h22,h23, h31,h32,1]
        return [b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], 1.0]
    }

    // MARK: - Build Pose Matrix with SVD Orthogonalization

    private func buildPose(
        r1: SIMD3<Float>, r2: SIMD3<Float>, r3: SIMD3<Float>, t: SIMD3<Float>
    ) -> simd_float4x4 {
        // Orthogonalize R = [r1|r2|r3] using SVD: R_approx = U*S*Vt → R = U*Vt
        // For 3×3, use LAPACK sgesvd_

        // Column-major 3×3
        var A: [Float] = [
            r1.x, r1.y, r1.z,  // column 0
            r2.x, r2.y, r2.z,  // column 1
            r3.x, r3.y, r3.z   // column 2
        ]

        var m: Int32 = 3, n: Int32 = 3
        var s = [Float](repeating: 0, count: 3)
        var u = [Float](repeating: 0, count: 9)
        var vt = [Float](repeating: 0, count: 9)
        var lda: Int32 = 3, ldu: Int32 = 3, ldvt: Int32 = 3
        var info: Int32 = 0

        // Query optimal workspace
        var lwork: Int32 = -1
        var workQuery = [Float](repeating: 0, count: 1)
        var jobu = Int8(UInt8(ascii: "A"))
        var jobvt = Int8(UInt8(ascii: "A"))

        sgesvd_(&jobu, &jobvt, &m, &n, &A, &lda, &s, &u, &ldu, &vt, &ldvt,
                &workQuery, &lwork, &info)
        lwork = Int32(workQuery[0])
        var work = [Float](repeating: 0, count: Int(lwork))

        sgesvd_(&jobu, &jobvt, &m, &n, &A, &lda, &s, &u, &ldu, &vt, &ldvt,
                &work, &lwork, &info)

        guard info == 0 else {
            // Fallback: use non-orthogonalized R
            return simd_float4x4(columns: (
                SIMD4<Float>(r1.x, r1.y, r1.z, 0),
                SIMD4<Float>(r2.x, r2.y, r2.z, 0),
                SIMD4<Float>(r3.x, r3.y, r3.z, 0),
                SIMD4<Float>(t.x, t.y, t.z, 1)
            ))
        }

        // R = U * Vt (column-major)
        // u is 3×3 column-major, vt is 3×3 column-major
        let U = simd_float3x3(columns: (
            SIMD3<Float>(u[0], u[1], u[2]),
            SIMD3<Float>(u[3], u[4], u[5]),
            SIMD3<Float>(u[6], u[7], u[8])
        ))
        let Vt = simd_float3x3(columns: (
            SIMD3<Float>(vt[0], vt[1], vt[2]),
            SIMD3<Float>(vt[3], vt[4], vt[5]),
            SIMD3<Float>(vt[6], vt[7], vt[8])
        ))

        var R = U * Vt

        // Ensure proper rotation (det = +1)
        let det = R.columns.0.x * (R.columns.1.y * R.columns.2.z - R.columns.1.z * R.columns.2.y)
                - R.columns.0.y * (R.columns.1.x * R.columns.2.z - R.columns.1.z * R.columns.2.x)
                + R.columns.0.z * (R.columns.1.x * R.columns.2.y - R.columns.1.y * R.columns.2.x)
        if det < 0 {
            // Flip last column of U and recompute
            let UFixed = simd_float3x3(columns: (
                U.columns.0, U.columns.1, -U.columns.2
            ))
            R = UFixed * Vt
        }

        return simd_float4x4(columns: (
            SIMD4<Float>(R.columns.0, 0),
            SIMD4<Float>(R.columns.1, 0),
            SIMD4<Float>(R.columns.2, 0),
            SIMD4<Float>(t.x, t.y, t.z, 1)
        ))
    }
}
