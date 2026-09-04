import Foundation

private func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let response = response as? HTTPURLResponse else {
        throw ConformanceError.invalidResponse("response is not HTTP")
    }
    return response
}

private func expect(_ response: HTTPURLResponse, _ status: Int, _ operation: String, body: Data = Data()) throws {
    guard response.statusCode == status else {
        let value = String(data: body, encoding: .utf8) ?? "<non-UTF8 body>"
        throw ConformanceError.invalidResponse("\(operation): expected \(status), received \(response.statusCode): \(value)")
    }
}

final class CancelDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Int, Never>?
    private var received = 0

    func run(_ request: URLRequest) async -> Int {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += data.count
        dataTask.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        continuation?.resume(returning: received)
        continuation = nil
        session.finishTasksAndInvalidate()
    }
}

final class S3ConformanceClient: Sendable {
    private let config: RuntimeConfig
    private let vector: StreamVector
    private let session: URLSession

    init(config: RuntimeConfig, vector: StreamVector) {
        self.config = config
        self.vector = vector
        self.session = URLSession(configuration: .ephemeral)
    }

    private func patternByte(_ offset: UInt64) -> UInt8 {
        UInt8((offset * UInt64(vector.patternMultiplier) + UInt64(vector.patternIncrement)) % UInt64(vector.patternModulus))
    }

    private func createPatternFile(size: UInt64, start: UInt64 = 0) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zigfs-swift-\(UUID().uuidString).bin")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ConformanceError.assertion("cannot create temporary pattern file")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var offset: UInt64 = 0
        while offset < size {
            let length = Int(min(UInt64(vector.chunkSize), size - offset))
            var data = Data(count: length)
            data.withUnsafeMutableBytes { raw in
                guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for index in 0..<length { bytes[index] = patternByte(start + offset + UInt64(index)) }
            }
            try handle.write(contentsOf: data)
            offset += UInt64(length)
        }
        return url
    }

    private func dataRequest(
        method: String,
        path: String,
        query: [[String]] = [],
        body: Data? = nil,
        headers: [String: String] = [:],
        payloadHash: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = try signedRequest(
            config: config,
            method: method,
            path: path,
            query: query,
            payloadHash: payloadHash ?? body.map(sha256Hex) ?? emptyPayloadHash,
            additionalHeaders: headers
        )
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        return (data, try httpResponse(response))
    }

    private func uploadFile(
        _ file: URL,
        method: String,
        path: String,
        query: [[String]] = []
    ) async throws -> (Data, HTTPURLResponse) {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        var request = try signedRequest(
            config: config,
            method: method,
            path: path,
            query: query,
            payloadHash: unsignedPayload,
            additionalHeaders: ["Content-Length": String(size)]
        )
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let (data, response) = try await session.upload(for: request, fromFile: file)
        return (data, try httpResponse(response))
    }

    func createBucket(_ bucket: String) async throws {
        let (createBody, createResponse) = try await dataRequest(method: "PUT", path: "/\(bucket)")
        try expect(createResponse, 200, "CreateBucket", body: createBody)
        let (headBody, headResponse) = try await dataRequest(method: "HEAD", path: "/\(bucket)")
        try expect(headResponse, 200, "HeadBucket", body: headBody)
    }

    func putPattern(bucket: String, key: String, size: UInt64, start: UInt64 = 0) async throws -> String {
        let file = try createPatternFile(size: size, start: start)
        defer { try? FileManager.default.removeItem(at: file) }
        let (body, response) = try await uploadFile(file, method: "PUT", path: "/\(bucket)/\(key)")
        try expect(response, 200, "PutObject", body: body)
        guard let etag = response.value(forHTTPHeaderField: "ETag") else {
            throw ConformanceError.invalidResponse("PutObject: missing ETag")
        }
        return etag
    }

    func putBytes(bucket: String, key: String, value: Data) async throws -> String {
        let (body, response) = try await dataRequest(method: "PUT", path: "/\(bucket)/\(key)", body: value)
        try expect(response, 200, "PutObject", body: body)
        guard let etag = response.value(forHTTPHeaderField: "ETag") else {
            throw ConformanceError.invalidResponse("PutObject: missing ETag")
        }
        return etag
    }

    func verifyPatternGet(bucket: String, key: String, size: UInt64, start: UInt64 = 0) async throws {
        let request = try signedRequest(config: config, method: "GET", path: "/\(bucket)/\(key)")
        let (bytes, rawResponse) = try await session.bytes(for: request)
        let response = try httpResponse(rawResponse)
        try expect(response, 200, "GetObject")
        var offset: UInt64 = 0
        for try await byte in bytes {
            try require(byte == patternByte(start + offset), "GetObject: byte mismatch at \(offset)")
            offset += 1
        }
        try require(offset == size, "GetObject: expected \(size) bytes, received \(offset)")
    }

    func verifyRange(bucket: String, key: String) async throws {
        let start = UInt64(vector.rangeStart)!
        let end = UInt64(vector.rangeEnd)!
        let (body, response) = try await dataRequest(
            method: "GET",
            path: "/\(bucket)/\(key)",
            headers: ["Range": "bytes=\(start)-\(end)"]
        )
        try expect(response, 206, "Range GetObject", body: body)
        try require(
            response.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(end)/\(vector.objectSize)",
            "Range: invalid Content-Range"
        )
        try require(UInt64(body.count) == end - start + 1, "Range: invalid body length")
        for (index, byte) in body.enumerated() {
            try require(byte == patternByte(start + UInt64(index)), "Range: byte mismatch")
        }
    }

    func verifyPagination(bucket: String) async throws {
        _ = try await putBytes(bucket: bucket, key: "page-a", value: Data("a".utf8))
        _ = try await putBytes(bucket: bucket, key: "page-b", value: Data("b".utf8))
        let query = [["list-type", "2"], ["max-keys", "1"], ["prefix", "page-"]]
        let (firstBody, firstResponse) = try await dataRequest(method: "GET", path: "/\(bucket)", query: query)
        try expect(firstResponse, 200, "ListObjectsV2 page 1", body: firstBody)
        let first = try parseXML(firstBody)
        guard let token = first["NextContinuationToken"]?.first else {
            throw ConformanceError.invalidResponse("ListObjectsV2: missing continuation token")
        }
        try require(first["Key"]?.first == "page-a", "ListObjectsV2: unexpected first key")
        let (secondBody, secondResponse) = try await dataRequest(
            method: "GET",
            path: "/\(bucket)",
            query: query + [["continuation-token", token]]
        )
        try expect(secondResponse, 200, "ListObjectsV2 page 2", body: secondBody)
        let second = try parseXML(secondBody)
        try require(second["Key"]?.first == "page-b", "ListObjectsV2: unexpected second key")
    }

    private func createMultipart(bucket: String, key: String) async throws -> String {
        let (body, response) = try await dataRequest(
            method: "POST",
            path: "/\(bucket)/\(key)",
            query: [["uploads", ""]]
        )
        try expect(response, 200, "CreateMultipartUpload", body: body)
        guard let uploadId = try parseXML(body)["UploadId"]?.first else {
            throw ConformanceError.invalidResponse("CreateMultipartUpload: missing UploadId")
        }
        return uploadId
    }

    private func uploadPart(
        bucket: String,
        key: String,
        uploadId: String,
        partNumber: Int,
        size: UInt64,
        start: UInt64
    ) async throws -> String {
        let file = try createPatternFile(size: size, start: start)
        defer { try? FileManager.default.removeItem(at: file) }
        let (body, response) = try await uploadFile(
            file,
            method: "PUT",
            path: "/\(bucket)/\(key)",
            query: [["partNumber", String(partNumber)], ["uploadId", uploadId]]
        )
        try expect(response, 200, "UploadPart \(partNumber)", body: body)
        guard let etag = response.value(forHTTPHeaderField: "ETag") else {
            throw ConformanceError.invalidResponse("UploadPart \(partNumber): missing ETag")
        }
        return etag
    }

    func verifyMultipart(bucket: String, key: String) async throws {
        let uploadId = try await createMultipart(bucket: bucket, key: key)
        let firstSize = UInt64(vector.multipartPartSizes[0])!
        let secondSize = UInt64(vector.multipartPartSizes[1])!
        let firstETag = try await uploadPart(bucket: bucket, key: key, uploadId: uploadId, partNumber: 1, size: firstSize, start: 0)
        let secondETag = try await uploadPart(bucket: bucket, key: key, uploadId: uploadId, partNumber: 2, size: secondSize, start: firstSize)

        let (listBody, listResponse) = try await dataRequest(
            method: "GET",
            path: "/\(bucket)/\(key)",
            query: [["uploadId", uploadId]]
        )
        try expect(listResponse, 200, "ListParts", body: listBody)
        let listedParts = try parseXML(listBody)
        try require(listedParts["PartNumber"] == ["1", "2"], "ListParts: unexpected parts")

        let complete = "<CompleteMultipartUpload><Part><ETag>\(xmlEscape(firstETag))</ETag><PartNumber>1</PartNumber></Part><Part><ETag>\(xmlEscape(secondETag))</ETag><PartNumber>2</PartNumber></Part></CompleteMultipartUpload>"
        let completeBody = Data(complete.utf8)
        let (resultBody, resultResponse) = try await dataRequest(
            method: "POST",
            path: "/\(bucket)/\(key)",
            query: [["uploadId", uploadId]],
            body: completeBody,
            headers: ["Content-Type": "application/xml"]
        )
        try expect(resultResponse, 200, "CompleteMultipartUpload", body: resultBody)
        try await verifyPatternGet(bucket: bucket, key: key, size: firstSize + secondSize)

        let abortedKey = "\(key)-aborted"
        let abortedId = try await createMultipart(bucket: bucket, key: abortedKey)
        let (abortBody, abortResponse) = try await dataRequest(
            method: "DELETE",
            path: "/\(bucket)/\(abortedKey)",
            query: [["uploadId", abortedId]]
        )
        try expect(abortResponse, 204, "AbortMultipartUpload", body: abortBody)
        let (missingBody, missingResponse) = try await dataRequest(
            method: "GET",
            path: "/\(bucket)/\(abortedKey)",
            query: [["uploadId", abortedId]]
        )
        try expect(missingResponse, 404, "aborted ListParts", body: missingBody)
        let missing = try parseXML(missingBody)
        try require(missing["Code"]?.first == "NoSuchUpload", "aborted ListParts: wrong error")
    }

    func verifyMissingError(bucket: String) async throws {
        let (body, response) = try await dataRequest(method: "GET", path: "/\(bucket)/missing-object")
        try expect(response, 404, "missing object", body: body)
        let values = try parseXML(body)
        try require(values["Code"]?.first == "NoSuchKey", "missing object: wrong error code")
        try require(
            values["RequestId"]?.first == response.value(forHTTPHeaderField: "X-Amz-Request-Id"),
            "missing object: Request ID mismatch"
        )
    }

    func verifyCancellation(bucket: String, key: String) async throws {
        let request = try signedRequest(config: config, method: "GET", path: "/\(bucket)/\(key)")
        let received = await CancelDelegate().run(request)
        try require(received > 0, "cancel GetObject: no first chunk")
        let (body, response) = try await dataRequest(method: "HEAD", path: "/\(bucket)/\(key)")
        try expect(response, 200, "HeadObject after cancel", body: body)
    }

    func deleteObject(bucket: String, key: String) async throws {
        let (body, response) = try await dataRequest(method: "DELETE", path: "/\(bucket)/\(key)")
        try expect(response, 204, "DeleteObject \(key)", body: body)
    }

    func deleteBucket(_ bucket: String) async throws {
        let (body, response) = try await dataRequest(method: "DELETE", path: "/\(bucket)")
        try expect(response, 204, "DeleteBucket", body: body)
    }
}
