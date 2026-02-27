//
//  RecordingItem.swift
//  iPhoneVIO
//
//  Data models for recording management API.
//

import Foundation

struct RecordingItem: Decodable, Identifiable {
    let sessionId: String
    let filename: String
    let sizeBytes: Int64
    let createdAt: Date
    let durationSecs: Double?
    let messageCount: Int?

    var id: String { sessionId }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case filename
        case sizeBytes = "size_bytes"
        case createdAt = "created_at"
        case durationSecs = "duration_secs"
        case messageCount = "message_count"
    }
}

struct RecordingsResponse: Decodable {
    let recordings: [RecordingItem]
    let totalSizeBytes: Int64
    let diskFreeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case recordings
        case totalSizeBytes = "total_size_bytes"
        case diskFreeBytes = "disk_free_bytes"
    }
}

struct ReplayStatus: Decodable {
    let active: Bool
    let sessionId: String?
    let progress: Double
    let elapsedSecs: Double
    let totalSecs: Double
    let speed: Double

    enum CodingKeys: String, CodingKey {
        case active
        case sessionId = "session_id"
        case progress
        case elapsedSecs = "elapsed_secs"
        case totalSecs = "total_secs"
        case speed
    }
}

struct ReplayStartResponse: Decodable {
    let sessionId: String
    let totalSecs: Double
    let messageCount: Int

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case totalSecs = "total_secs"
        case messageCount = "message_count"
    }
}

struct BatchDeleteRequest: Encodable {
    let sessionIds: [String]

    enum CodingKeys: String, CodingKey {
        case sessionIds = "session_ids"
    }
}

struct BatchDeleteResponse: Decodable {
    let deleted: [String]
    let failed: [BatchDeleteFailure]
}

struct BatchDeleteFailure: Decodable {
    let sessionId: String
    let error: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case error
    }
}
