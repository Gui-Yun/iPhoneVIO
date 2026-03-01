import Foundation
import Accelerate
import simd
import CoreVideo

struct ArucoDetectionResult {
    let markerId: Int
    let corners: [SIMD2<Float>]       // 4 corners in full-resolution pixel coordinates
    let worldTransform: simd_float4x4  // marker pose in ARKit world coordinates
}

struct ArucoDebugInfo {
    let contourCount: Int
    let quadCount: Int
    let candidateCount: Int
    let decodedBits: UInt16?
    let borderOK: Bool
    let matchedId: Int?
}

/// Native Swift ArUco marker detector.
/// Pipeline: Y-plane extraction → downsample → adaptive threshold (multi-window)
/// → contour detection → quad filtering → perspective correct → bit decode → PnP.
class ArucoDetector {
    private let dictionary = ArucoDictionary()
    private let pnpSolver = PnPSolver()
    private let detectQueue = DispatchQueue(label: "com.iphoneVIO.aruco", qos: .userInitiated)
    private let markerSizeMeters: Float = 0.16

    private let downsampleScale: Int = 4       // 1920/4=480, 1440/4=360
    private let windowSizes = [7, 13, 23]
    private let thresholdC: Int32 = 7
    private let minPerimeterRate: Float = 0.03
    private let maxPerimeterRate: Float = 4.0
    private let polygonApproxRate: Float = 0.03
    private let minCornerDistRate: Float = 0.05
    private let maxHammingDist: Int = 2

    private var isProcessing = false
    private var lastDebugLogTime: TimeInterval = 0
    private(set) var lastDebugInfo = ArucoDebugInfo(
        contourCount: 0, quadCount: 0, candidateCount: 0,
        decodedBits: nil, borderOK: false, matchedId: nil
    )

    // MARK: - Public API

    func detect(
        pixelBuffer: CVPixelBuffer,
        intrinsics: simd_float3x3,
        cameraTransform: simd_float4x4,
        completion: @escaping (ArucoDetectionResult?) -> Void
    ) {
        guard !isProcessing else {
            return  // Silently skip — don't disturb the caller's state machine
        }
        isProcessing = true

        // Extract Y plane + downsample SYNCHRONOUSLY to release the pixel buffer
        // immediately and avoid retaining ARFrames in the async closure.
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let fullW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let fullH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            isProcessing = false
            completion(nil)
            return
        }

        let dsW = fullW / downsampleScale
        let dsH = fullH / downsampleScale
        var srcBuf = vImage_Buffer(data: yBase, height: vImagePixelCount(fullH),
                                   width: vImagePixelCount(fullW), rowBytes: yRowBytes)
        var dsData = [UInt8](repeating: 0, count: dsW * dsH)
        dsData.withUnsafeMutableBufferPointer { bufPtr in
            var dsBuf = vImage_Buffer(data: bufPtr.baseAddress!, height: vImagePixelCount(dsH),
                                      width: vImagePixelCount(dsW), rowBytes: dsW)
            vImageScale_Planar8(&srcBuf, &dsBuf, nil, vImage_Flags(kvImageNoFlags))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        // Pixel buffer released — ARFrame can be recycled now.

        detectQueue.async { [self] in
            defer { isProcessing = false }
            let result = processDownsampled(
                dsData: dsData, dsW: dsW, dsH: dsH,
                fullW: fullW, fullH: fullH,
                intrinsics: intrinsics,
                cameraTransform: cameraTransform
            )
            completion(result)
        }
    }

    // MARK: - Detection Pipeline (on background queue, no CVPixelBuffer reference)

    private func processDownsampled(
        dsData: [UInt8], dsW: Int, dsH: Int,
        fullW: Int, fullH: Int,
        intrinsics: simd_float3x3,
        cameraTransform: simd_float4x4
    ) -> ArucoDetectionResult? {

        // 3. Multi-window adaptive threshold → candidate quads
        var allCandidates: [[SIMD2<Float>]] = []
        var totalContours = 0
        var totalQuads = 0
        for ws in windowSizes {
            let binary = adaptiveThreshold(dsData, w: dsW, h: dsH, winSize: ws)
            let contours = findContours(binary, w: dsW, h: dsH)
            totalContours += contours.count
            let quads = filterQuads(contours, imgW: dsW, imgH: dsH)
            totalQuads += quads.count
            allCandidates.append(contentsOf: quads)
        }

        // 4. Deduplicate
        let candidates = deduplicate(allCandidates)

        // 5. For each candidate: perspective correct → decode → PnP
        var lastBits: UInt16? = nil
        var lastBorderOK = false
        var lastMatchId: Int? = nil

        for corners in candidates {
            let ordered = orderCorners(corners)

            guard let canonical = perspectiveCorrect(
                dsData, w: dsW, h: dsH, corners: ordered, outSize: 36
            ) else { continue }

            guard let (bits, borderOK) = extractBits(canonical, gridSize: 6, cellSize: 6) else {
                continue
            }
            lastBits = bits
            lastBorderOK = borderOK

            guard borderOK else { continue }

            if let match = dictionary.match(bits: bits, maxHamming: maxHammingDist) {
                lastMatchId = match.id

                // Map corners back to full resolution
                let scale = Float(downsampleScale)
                let fullCorners = ordered.map { SIMD2<Float>($0.x * scale, $0.y * scale) }

                guard let cameraPose = pnpSolver.solve(
                    imagePoints: fullCorners,
                    markerSize: markerSizeMeters,
                    intrinsics: intrinsics
                ) else { continue }

                // PnP returns OpenCV convention (Y-down, Z-forward).
                // ARKit camera frame is Y-up, Z-backward. Flip Y and Z.
                let flipYZ = simd_float4x4(diagonal: SIMD4<Float>(1, -1, -1, 1))
                let worldTransform = cameraTransform * flipYZ * cameraPose

                lastDebugInfo = ArucoDebugInfo(
                    contourCount: totalContours, quadCount: totalQuads,
                    candidateCount: candidates.count, decodedBits: bits,
                    borderOK: borderOK, matchedId: match.id
                )
                return ArucoDetectionResult(
                    markerId: match.id,
                    corners: fullCorners,
                    worldTransform: worldTransform
                )
            }
        }

        // Debug logging (once per second)
        let now = Date().timeIntervalSince1970
        lastDebugInfo = ArucoDebugInfo(
            contourCount: totalContours, quadCount: totalQuads,
            candidateCount: candidates.count, decodedBits: lastBits,
            borderOK: lastBorderOK, matchedId: lastMatchId
        )
        if now - lastDebugLogTime >= 1.0 {
            lastDebugLogTime = now
            let bitsStr = lastBits.map { String(format: "0x%04X", $0) } ?? "nil"
            print("[ArUco] contours=\(totalContours) quads=\(totalQuads) candidates=\(candidates.count) bits=\(bitsStr) border=\(lastBorderOK) match=\(lastMatchId.map { String($0) } ?? "nil")")
        }
        return nil
    }

    // MARK: - Adaptive Threshold (integral image)

    private func adaptiveThreshold(_ img: [UInt8], w: Int, h: Int, winSize: Int) -> [UInt8] {
        let half = winSize / 2

        // Build integral image
        let iw = w + 1
        var integral = [Int32](repeating: 0, count: iw * (h + 1))
        for y in 0..<h {
            var rowSum: Int32 = 0
            for x in 0..<w {
                rowSum += Int32(img[y * w + x])
                integral[(y + 1) * iw + (x + 1)] = integral[y * iw + (x + 1)] + rowSum
            }
        }

        var result = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - half)
            let y1 = min(h - 1, y + half)
            for x in 0..<w {
                let x0 = max(0, x - half)
                let x1 = min(w - 1, x + half)
                let area = Int32((x1 - x0 + 1) * (y1 - y0 + 1))
                let sum = integral[(y1+1)*iw + (x1+1)]
                        - integral[y0*iw + (x1+1)]
                        - integral[(y1+1)*iw + x0]
                        + integral[y0*iw + x0]
                let mean = sum / area
                result[y * w + x] = Int32(img[y * w + x]) > mean - thresholdC ? 255 : 0
            }
        }
        return result
    }

    // MARK: - Contour Detection (Moore Boundary Tracing)

    private func findContours(_ binary: [UInt8], w: Int, h: Int) -> [[(Int, Int)]] {
        var visited = [Bool](repeating: false, count: w * h)
        var contours: [[(Int, Int)]] = []

        let dx = [1, 1, 0, -1, -1, -1, 0, 1]
        let dy = [0, 1, 1, 1, 0, -1, -1, -1]

        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let idx = y * w + x
                guard binary[idx] == 255 && binary[idx - 1] == 0 && !visited[idx] else { continue }

                var contour: [(Int, Int)] = []
                var cx = x, cy = y, dir = 0
                let maxSteps = w * h

                repeat {
                    contour.append((cx, cy))
                    visited[cy * w + cx] = true

                    var found = false
                    let searchStart = (dir + 5) % 8
                    for i in 0..<8 {
                        let d = (searchStart + i) % 8
                        let nx = cx + dx[d], ny = cy + dy[d]
                        if nx >= 0 && nx < w && ny >= 0 && ny < h && binary[ny * w + nx] == 255 {
                            cx = nx; cy = ny; dir = d; found = true
                            break
                        }
                    }
                    if !found { break }
                } while (cx != x || cy != y) && contour.count < maxSteps

                if contour.count >= 10 {
                    contours.append(contour)
                }
            }
        }
        return contours
    }

    // MARK: - Polygon Approximation (Ramer-Douglas-Peucker)

    private func approxPolyDP(_ pts: [(Int, Int)], epsilon: Float) -> [(Int, Int)] {
        guard pts.count >= 4 else { return pts }

        // Find two farthest points to split closed contour
        var maxD: Float = 0; var i1 = 0, i2 = 0
        let n = pts.count
        // Sample evenly to avoid O(n^2) for large contours
        let step = max(1, n / 50)
        for i in stride(from: 0, to: n, by: step) {
            for j in stride(from: i + 1, to: n, by: step) {
                let d = dist2(pts[i], pts[j])
                if d > maxD { maxD = d; i1 = i; i2 = j }
            }
        }
        if i1 > i2 { swap(&i1, &i2) }

        let half1 = Array(pts[i1...i2])
        let half2 = Array(pts[i2...]) + Array(pts[..<i1]) + [pts[i1]]

        let s1 = rdp(half1, eps: epsilon)
        let s2 = rdp(half2, eps: epsilon)

        var result = s1
        if s2.count > 1 {
            result.append(contentsOf: s2[1..<(s2.count - 1)])
        }
        return result
    }

    private func rdp(_ pts: [(Int, Int)], eps: Float) -> [(Int, Int)] {
        guard pts.count > 2 else { return pts }
        let first = pts.first!, last = pts.last!
        var maxD: Float = 0; var maxIdx = 0
        for i in 1..<(pts.count - 1) {
            let d = pointLineDist(pts[i], first, last)
            if d > maxD { maxD = d; maxIdx = i }
        }
        if maxD > eps {
            let left = rdp(Array(pts[...maxIdx]), eps: eps)
            let right = rdp(Array(pts[maxIdx...]), eps: eps)
            return left + Array(right.dropFirst())
        }
        return [first, last]
    }

    private func pointLineDist(_ p: (Int, Int), _ a: (Int, Int), _ b: (Int, Int)) -> Float {
        let px = Float(p.0), py = Float(p.1)
        let ax = Float(a.0), ay = Float(a.1)
        let bx = Float(b.0), by = Float(b.1)
        let dx = bx - ax, dy = by - ay
        let lenSq = dx * dx + dy * dy
        if lenSq < 1e-10 { return sqrt((px-ax)*(px-ax) + (py-ay)*(py-ay)) }
        return abs((px - ax) * dy - (py - ay) * dx) / sqrt(lenSq)
    }

    private func dist2(_ a: (Int, Int), _ b: (Int, Int)) -> Float {
        let dx = Float(a.0 - b.0), dy = Float(a.1 - b.1)
        return dx * dx + dy * dy
    }

    // MARK: - Quad Filtering

    private func filterQuads(_ contours: [[(Int, Int)]], imgW: Int, imgH: Int) -> [[SIMD2<Float>]] {
        let imgPerim = Float(2 * (imgW + imgH))
        var quads: [[SIMD2<Float>]] = []

        for contour in contours {
            let perim = contourPerimeter(contour)
            guard perim > imgPerim * minPerimeterRate,
                  perim < imgPerim * maxPerimeterRate else { continue }

            let approx = approxPolyDP(contour, epsilon: perim * polygonApproxRate)
            guard approx.count == 4 else { continue }

            let corners = approx.map { SIMD2<Float>(Float($0.0), Float($0.1)) }
            guard isConvex(corners) else { continue }

            let minSide = minSideLen(corners)
            guard minSide > perim * minCornerDistRate else { continue }

            quads.append(corners)
        }
        return quads
    }

    private func contourPerimeter(_ c: [(Int, Int)]) -> Float {
        guard c.count >= 2 else { return 0 }
        var p: Float = 0
        for i in 0..<c.count {
            let j = (i + 1) % c.count
            let dx = Float(c[i].0 - c[j].0), dy = Float(c[i].1 - c[j].1)
            p += sqrt(dx * dx + dy * dy)
        }
        return p
    }

    private func isConvex(_ c: [SIMD2<Float>]) -> Bool {
        var sign: Float = 0
        for i in 0..<c.count {
            let a = c[i], b = c[(i+1) % c.count], cc = c[(i+2) % c.count]
            let cross = (b.x - a.x) * (cc.y - b.y) - (b.y - a.y) * (cc.x - b.x)
            if sign == 0 { sign = cross }
            else if sign * cross < 0 { return false }
        }
        return true
    }

    private func minSideLen(_ c: [SIMD2<Float>]) -> Float {
        var m: Float = .greatestFiniteMagnitude
        for i in 0..<c.count {
            m = min(m, simd_distance(c[i], c[(i+1) % c.count]))
        }
        return m
    }

    // MARK: - Deduplication

    private func deduplicate(_ candidates: [[SIMD2<Float>]]) -> [[SIMD2<Float>]] {
        guard candidates.count > 1 else { return candidates }
        var keep = [Bool](repeating: true, count: candidates.count)
        for i in 0..<candidates.count {
            guard keep[i] else { continue }
            let ci = centroid(candidates[i])
            for j in (i+1)..<candidates.count {
                guard keep[j] else { continue }
                if simd_distance(ci, centroid(candidates[j])) < 10 {
                    let pi = quadPerim(candidates[i]), pj = quadPerim(candidates[j])
                    keep[pi >= pj ? j : i] = false
                }
            }
        }
        return candidates.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    private func centroid(_ c: [SIMD2<Float>]) -> SIMD2<Float> {
        c.reduce(.zero, +) / Float(c.count)
    }

    private func quadPerim(_ c: [SIMD2<Float>]) -> Float {
        (0..<4).reduce(Float(0)) { $0 + simd_distance(c[$1], c[($1+1) % 4]) }
    }

    // MARK: - Corner Ordering (TL, TR, BR, BL)

    private func orderCorners(_ corners: [SIMD2<Float>]) -> [SIMD2<Float>] {
        // Sort by sum (x+y) and difference (x-y) to find TL/TR/BR/BL
        let sorted = corners.sorted { ($0.x + $0.y) < ($1.x + $1.y) }
        let tl = sorted[0], br = sorted[3]
        let remaining = [sorted[1], sorted[2]]
        // Of the two middle points, the one with larger x-y is TR
        let tr = remaining.max(by: { ($0.x - $0.y) < ($1.x - $1.y) })!
        let bl = remaining.min(by: { ($0.x - $0.y) < ($1.x - $1.y) })!
        return [tl, tr, br, bl]
    }

    // MARK: - Perspective Correction

    private func perspectiveCorrect(
        _ img: [UInt8], w: Int, h: Int,
        corners: [SIMD2<Float>], outSize: Int
    ) -> [UInt8]? {
        let s = Float(outSize - 1)
        let dst: [SIMD2<Float>] = [
            SIMD2<Float>(0, 0), SIMD2<Float>(s, 0),
            SIMD2<Float>(s, s), SIMD2<Float>(0, s)
        ]

        // Inverse homography: output coords → input coords
        guard let H = computeHomography(from: dst, to: corners) else { return nil }

        var output = [UInt8](repeating: 0, count: outSize * outSize)
        for y in 0..<outSize {
            for x in 0..<outSize {
                let px = Float(x), py = Float(y)
                let ww = H[6] * px + H[7] * py + H[8]
                guard abs(ww) > 1e-10 else { continue }
                let sx = (H[0] * px + H[1] * py + H[2]) / ww
                let sy = (H[3] * px + H[4] * py + H[5]) / ww

                let ix = Int(sx), iy = Int(sy)
                guard ix >= 0 && ix < w - 1 && iy >= 0 && iy < h - 1 else { continue }

                let fx = sx - Float(ix), fy = sy - Float(iy)
                let v00 = Float(img[iy * w + ix])
                let v10 = Float(img[iy * w + ix + 1])
                let v01 = Float(img[(iy+1) * w + ix])
                let v11 = Float(img[(iy+1) * w + ix + 1])
                let val = v00*(1-fx)*(1-fy) + v10*fx*(1-fy) + v01*(1-fx)*fy + v11*fx*fy
                output[y * outSize + x] = UInt8(max(0, min(255, val)))
            }
        }
        return output
    }

    /// 3×3 homography (row-major, 9 elements) from 4 point pairs via DLT.
    private func computeHomography(
        from src: [SIMD2<Float>], to dst: [SIMD2<Float>]
    ) -> [Float]? {
        var M = [Float](repeating: 0, count: 64)
        var b = [Float](repeating: 0, count: 8)

        for i in 0..<4 {
            let sx = src[i].x, sy = src[i].y
            let dx = dst[i].x, dy = dst[i].y
            let r0 = i * 2, r1 = r0 + 1

            M[r0 + 0*8] = sx; M[r0 + 1*8] = sy; M[r0 + 2*8] = 1
            M[r0 + 3*8] = 0;  M[r0 + 4*8] = 0;  M[r0 + 5*8] = 0
            M[r0 + 6*8] = -sx*dx; M[r0 + 7*8] = -sy*dx
            b[r0] = dx

            M[r1 + 0*8] = 0;  M[r1 + 1*8] = 0;  M[r1 + 2*8] = 0
            M[r1 + 3*8] = sx; M[r1 + 4*8] = sy; M[r1 + 5*8] = 1
            M[r1 + 6*8] = -sx*dy; M[r1 + 7*8] = -sy*dy
            b[r1] = dy
        }

        var n: Int32 = 8, nrhs: Int32 = 1, lda: Int32 = 8
        var ipiv = [Int32](repeating: 0, count: 8)
        var ldb: Int32 = 8, info: Int32 = 0
        sgesv_(&n, &nrhs, &M, &lda, &ipiv, &b, &ldb, &info)
        guard info == 0 else { return nil }

        return [b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], 1.0]
    }

    // MARK: - Bit Extraction

    private func extractBits(
        _ img: [UInt8], gridSize: Int, cellSize: Int
    ) -> (bits: UInt16, borderOK: Bool)? {
        let size = gridSize * cellSize
        guard img.count == size * size else { return nil }

        // Check border cells are black
        var borderOK = true
        let halfCell = cellSize / 2
        let margin = cellSize / 4

        // Top and bottom rows
        outerCheck: for col in 0..<gridSize {
            let cx = col * cellSize + halfCell
            for row in [0, gridSize - 1] {
                let cy = row * cellSize + halfCell
                if sampleCell(img, size: size, cx: cx, cy: cy, margin: margin) > 128 {
                    borderOK = false
                    break outerCheck
                }
            }
        }

        if borderOK {
            // Left and right columns (skip corners already checked)
            outerCheck2: for row in 1..<(gridSize - 1) {
                let cy = row * cellSize + halfCell
                for col in [0, gridSize - 1] {
                    let cx = col * cellSize + halfCell
                    if sampleCell(img, size: size, cx: cx, cy: cy, margin: margin) > 128 {
                        borderOK = false
                        break outerCheck2
                    }
                }
            }
        }

        // Extract inner 4×4 bits
        let innerSize = gridSize - 2
        var innerValues = [UInt8]()
        innerValues.reserveCapacity(innerSize * innerSize)
        for row in 0..<innerSize {
            for col in 0..<innerSize {
                let cy = (row + 1) * cellSize + halfCell
                let cx = (col + 1) * cellSize + halfCell
                innerValues.append(sampleCell(img, size: size, cx: cx, cy: cy, margin: margin))
            }
        }

        let threshold = otsuThreshold(innerValues)
        var bits: UInt16 = 0
        for (i, val) in innerValues.enumerated() {
            if val > threshold {
                bits |= (1 << (15 - i))
            }
        }
        return (bits, borderOK)
    }

    private func sampleCell(_ img: [UInt8], size: Int, cx: Int, cy: Int, margin: Int) -> UInt8 {
        var sum = 0, count = 0
        for dy in -margin...margin {
            for dx in -margin...margin {
                let py = cy + dy, px = cx + dx
                if py >= 0 && py < size && px >= 0 && px < size {
                    sum += Int(img[py * size + px])
                    count += 1
                }
            }
        }
        return UInt8(sum / max(1, count))
    }

    private func otsuThreshold(_ values: [UInt8]) -> UInt8 {
        guard !values.isEmpty else { return 128 }
        var hist = [Int](repeating: 0, count: 256)
        for v in values { hist[Int(v)] += 1 }
        let total = values.count
        var sumAll: Float = 0
        for i in 0..<256 { sumAll += Float(i) * Float(hist[i]) }

        var sumB: Float = 0, wB = 0
        var maxVar: Float = 0, best: UInt8 = 128
        for t in 0..<256 {
            wB += hist[t]
            guard wB > 0 else { continue }
            let wF = total - wB
            guard wF > 0 else { break }
            sumB += Float(t) * Float(hist[t])
            let mB = sumB / Float(wB), mF = (sumAll - sumB) / Float(wF)
            let v = Float(wB) * Float(wF) * (mB - mF) * (mB - mF)
            if v > maxVar { maxVar = v; best = UInt8(t) }
        }
        return best
    }
}
