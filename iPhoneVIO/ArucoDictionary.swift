import Foundation

/// DICT_4X4_50 ArUco dictionary — first 50 markers from OpenCV's DICT_4X4_1000.
/// Each marker is a 4×4 bit grid stored as UInt16 (MSB = row0col0, LSB = row3col3).
struct ArucoDictionary {

    struct Match {
        let id: Int        // marker ID (0..49)
        let rotation: Int  // 0=canonical, 1=90°CW, 2=180°, 3=270°CW
        let hamming: Int   // Hamming distance from dictionary entry
    }

    // Canonical patterns (rotation 0) from OpenCV predefined_dictionaries.hpp
    private static let markers: [UInt16] = [
        0xB532, // ID  0
        0x0F9A, // ID  1
        0x332D, // ID  2
        0x9946, // ID  3
        0x549E, // ID  4
        0x79CD, // ID  5
        0x9E2E, // ID  6
        0xC4F2, // ID  7
        0xFEDA, // ID  8
        0xCF56, // ID  9
        0xF991, // ID 10
        0x11A7, // ID 11
        0x0EB7, // ID 12
        0x2A0F, // ID 13
        0x24B1, // ID 14
        0x263E, // ID 15
        0x4665, // ID 16
        0x6600, // ID 17
        0x6C5E, // ID 18
        0x76AF, // ID 19
        0x868B, // ID 20
        0xB02B, // ID 21
        0xCCD5, // ID 22
        0xDD82, // ID 23
        0xFE47, // ID 24
        0x9471, // ID 25
        0xACE4, // ID 26
        0xA554, // ID 27
        0x2123, // ID 28
        0x346F, // ID 29
        0x4415, // ID 30
        0x57B2, // ID 31
        0x9ECF, // ID 32
        0xF0CB, // ID 33
        0x08AE, // ID 34
        0x0929, // ID 35
        0x1875, // ID 36
        0x04FF, // ID 37
        0x0DF6, // ID 38
        0x1C5A, // ID 39
        0x1718, // ID 40
        0x2A28, // ID 41
        0x328C, // ID 42
        0x38B2, // ID 43
        0x24E8, // ID 44
        0x2EEB, // ID 45
        0x2D3F, // ID 46
        0x4B64, // ID 47
        0x502E, // ID 48
        0x5013, // ID 49
    ]

    // Precomputed: all 4 rotations for each marker [id][rotation]
    private let allRotations: [[UInt16]]

    init() {
        allRotations = Self.markers.map { canonical in
            var rots = [UInt16](repeating: 0, count: 4)
            rots[0] = canonical
            rots[1] = Self.rotateCW(canonical)
            rots[2] = Self.rotateCW(rots[1])
            rots[3] = Self.rotateCW(rots[2])
            return rots
        }
    }

    /// Match detected bits against the dictionary.
    /// Tests all 4 rotations of each dictionary entry against the detected bits.
    func match(bits: UInt16, maxHamming: Int) -> Match? {
        var bestMatch: Match?
        var bestDist = maxHamming + 1

        for id in 0..<allRotations.count {
            for rot in 0..<4 {
                let dist = Self.hamming(bits, allRotations[id][rot])
                if dist < bestDist {
                    bestDist = dist
                    bestMatch = Match(id: id, rotation: rot, hamming: dist)
                }
            }
        }
        return bestMatch
    }

    // MARK: - Utilities

    /// Rotate a 4×4 bit pattern 90° clockwise.
    /// Mapping: new(row, col) = old(3-col, row)
    private static func rotateCW(_ bits: UInt16) -> UInt16 {
        var result: UInt16 = 0
        for row in 0..<4 {
            for col in 0..<4 {
                let srcRow = 3 - col
                let srcCol = row
                let srcBit = 15 - (srcRow * 4 + srcCol)
                let dstBit = 15 - (row * 4 + col)
                if bits & (1 << srcBit) != 0 {
                    result |= (1 << dstBit)
                }
            }
        }
        return result
    }

    /// Hamming distance between two 16-bit patterns.
    private static func hamming(_ a: UInt16, _ b: UInt16) -> Int {
        return (a ^ b).nonzeroBitCount
    }
}
