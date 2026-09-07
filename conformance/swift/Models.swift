import Foundation

struct RuntimeConfig: Decodable, Sendable {
    let endpoint: String
    let accessKey: String
    let secretKey: String
    let region: String
    let owner: String
}

struct SigV4Vector: Decodable, Sendable {
    let method: String
    let path: String
    let query: [[String]]
    let headers: [[String]]
    let signedHeaders: String
    let payloadHash: String
    let accessKey: String
    let secretKey: String
    let scopeDate: String
    let amzDate: String
    let region: String
    let service: String
    let expectedSignature: String
}

struct ErrorVector: Decodable, Sendable {
    let status: Int
    let xml: String
    let code: String
    let requestId: String
    let retryable: Bool
}

struct OperationContract: Decodable, Sendable {
    let operation: String
    let method: String
    let status: Int
    let response: String
}

struct ChecksumAlgorithm: Decodable, Sendable {
    let name: String
    let header: String
    let encoding: String
}

struct S3Contract: Decodable, Sendable {
    let operationContracts: [OperationContract]
    let checksumAlgorithms: [ChecksumAlgorithm]
    let etagExamples: [String]
    let sessionTokenHeader: String
    let postPolicyFileField: String
    let postPolicySuccessStatuses: [Int]
}

struct RetryVector: Decodable, Sendable {
    let operation: String
    let method: String
    let status: Int
    let bodyReplayable: Bool
    let responseStarted: Bool
    let cancelled: Bool
    let expected: Bool
}

struct StreamVector: Decodable, Sendable {
    let objectSize: String
    let multipartPartSizes: [String]
    let chunkSize: Int
    let rangeStart: String
    let rangeEnd: String
    let patternMultiplier: Int
    let patternIncrement: Int
    let patternModulus: Int
}

struct Fixture: Decodable, Sendable {
    let schemaVersion: Int
    let vectorRevision: Int
    let sigv4: SigV4Vector
    let uint64Values: [String]
    let opaqueValues: [String]
    let errors: [ErrorVector]
    let s3Contract: S3Contract
    let retryCases: [RetryVector]
    let stream: StreamVector
}

enum ConformanceError: Error, CustomStringConvertible {
    case assertion(String)
    case invalidResponse(String)

    var description: String {
        switch self {
        case .assertion(let message), .invalidResponse(let message):
            return message
        }
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ConformanceError.assertion(message) }
}
