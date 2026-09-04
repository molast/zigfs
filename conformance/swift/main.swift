import Foundation

func shouldRetry(_ value: RetryVector) -> Bool {
    if value.cancelled || value.responseStarted || value.status < 500 { return false }
    if value.operation == "create_multipart" || value.operation == "complete_multipart" { return false }
    if (value.method == "PUT" || value.method == "POST") && !value.bodyReplayable { return false }
    return ["GET", "HEAD", "DELETE", "PUT"].contains(value.method)
}

func loadJSON<T: Decodable>(_ type: T.Type, path: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

func verifySharedVectors(_ fixture: Fixture) throws {
    try require(fixture.schemaVersion == 1, "unsupported fixture schema")
    try require(signature(for: fixture.sigv4) == fixture.sigv4.expectedSignature, "SigV4 vector mismatch")

    let values = try fixture.uint64Values.map {
        guard let value = UInt64($0) else { throw ConformanceError.assertion("invalid UInt64 vector") }
        return value
    }
    try require(values[1] > 9_007_199_254_740_991, "UInt64 vector did not cross JavaScript safe integer limit")
    try require(values[2] == UInt64.max, "UInt64 maximum lost precision")
    try require(values.map(String.init).joined(separator: ",") == fixture.uint64Values.joined(separator: ","), "UInt64 round trip failed")

    for value in fixture.opaqueValues { try require(String(value) == value, "opaque value changed") }
    for value in fixture.errors {
        let parsed = try parseXML(value.xml)
        try require(parsed["Code"]?.first == value.code, "error code mismatch for \(value.code)")
        try require(parsed["RequestId"]?.first == value.requestId, "request ID mismatch for \(value.code)")
        try require((value.status >= 500) == value.retryable, "retryable mismatch for \(value.code)")
    }
    for value in fixture.retryCases {
        try require(shouldRetry(value) == value.expected, "retry decision mismatch for \(value.operation)")
    }
}

@main
struct SwiftConformance {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let configPath = environment["ZIGFS_CONFORMANCE_CONFIG"],
              let fixturePath = environment["ZIGFS_CONFORMANCE_FIXTURE"] else {
            throw ConformanceError.assertion("ZIGFS_CONFORMANCE_CONFIG and ZIGFS_CONFORMANCE_FIXTURE are required")
        }
        let config = try loadJSON(RuntimeConfig.self, path: configPath)
        let fixture = try loadJSON(Fixture.self, path: fixturePath)
        try verifySharedVectors(fixture)

        let suffix = String(UInt64(Date().timeIntervalSince1970 * 1_000), radix: 36)
        let bucket = "phase7-swift-\(suffix)"
        let objectKey = "stream-object.bin"
        let multipartKey = "multipart-object.bin"
        let cleanup = ["page-a", "page-b", objectKey, multipartKey]
        let client = S3ConformanceClient(config: config, vector: fixture.stream)

        do {
            try await client.createBucket(bucket)
            _ = try await client.putPattern(bucket: bucket, key: objectKey, size: UInt64(fixture.stream.objectSize)!)
            try await client.verifyPatternGet(bucket: bucket, key: objectKey, size: UInt64(fixture.stream.objectSize)!)
            try await client.verifyRange(bucket: bucket, key: objectKey)
            try await client.verifyPagination(bucket: bucket)
            try await client.verifyMultipart(bucket: bucket, key: multipartKey)
            try await client.verifyMissingError(bucket: bucket)
            try await client.verifyCancellation(bucket: bucket, key: objectKey)
        } catch {
            for key in cleanup { try? await client.deleteObject(bucket: bucket, key: key) }
            try? await client.deleteBucket(bucket)
            throw error
        }

        for key in cleanup { try await client.deleteObject(bucket: bucket, key: key) }
        try await client.deleteBucket(bucket)
        print("Swift/iOS conformance: PASS")
    }
}
