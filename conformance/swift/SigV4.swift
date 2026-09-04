import CryptoKit
import Foundation

let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
let unsignedPayload = "UNSIGNED-PAYLOAD"

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func sha256Hex(_ value: String) -> String {
    sha256Hex(Data(value.utf8))
}

private func hmac(key: Data, value: String) -> Data {
    let code = HMAC<SHA256>.authenticationCode(
        for: Data(value.utf8),
        using: SymmetricKey(data: key)
    )
    return Data(code)
}

private func hmac(key: String, value: String) -> Data {
    hmac(key: Data(key.utf8), value: value)
}

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func encodeComponent(_ value: String) -> String {
    var encoded = ""
    for byte in value.utf8 {
        let isAllowed = (byte >= 65 && byte <= 90) ||
            (byte >= 97 && byte <= 122) ||
            (byte >= 48 && byte <= 57) ||
            byte == 45 || byte == 46 || byte == 95 || byte == 126
        if isAllowed {
            encoded.append(Character(UnicodeScalar(byte)))
        } else {
            encoded += String(format: "%%%02X", byte)
        }
    }
    return encoded
}

func canonicalPath(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: false)
        .map { encodeComponent(String($0)) }
        .joined(separator: "/")
}

func canonicalQuery(_ query: [[String]]) -> String {
    query.map { [encodeComponent($0[0]), encodeComponent($0[1])] }
        .sorted {
            if $0[0] == $1[0] { return $0[1] < $1[1] }
            return $0[0] < $1[0]
        }
        .map { "\($0[0])=\($0[1])" }
        .joined(separator: "&")
}

private func normalizedHeaderValue(_ value: String) -> String {
    value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func calculateSignature(
    secretKey: String,
    scopeDate: String,
    region: String,
    service: String,
    stringToSign: String
) -> String {
    let dateKey = hmac(key: "AWS4\(secretKey)", value: scopeDate)
    let regionKey = hmac(key: dateKey, value: region)
    let serviceKey = hmac(key: regionKey, value: service)
    let signingKey = hmac(key: serviceKey, value: "aws4_request")
    return hex(hmac(key: signingKey, value: stringToSign))
}

func signature(for vector: SigV4Vector) -> String {
    let canonicalHeaders = vector.headers.map {
        "\($0[0].lowercased()):\(normalizedHeaderValue($0[1]))\n"
    }.joined()
    let canonicalRequest = [
        vector.method,
        vector.path,
        canonicalQuery(vector.query),
        canonicalHeaders,
        vector.signedHeaders,
        vector.payloadHash,
    ].joined(separator: "\n")
    let scope = "\(vector.scopeDate)/\(vector.region)/\(vector.service)/aws4_request"
    let stringToSign = [
        "AWS4-HMAC-SHA256",
        vector.amzDate,
        scope,
        sha256Hex(canonicalRequest),
    ].joined(separator: "\n")
    return calculateSignature(
        secretKey: vector.secretKey,
        scopeDate: vector.scopeDate,
        region: vector.region,
        service: vector.service,
        stringToSign: stringToSign
    )
}

private func timestamps(_ date: Date) -> (amzDate: String, scopeDate: String) {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    let amzDate = formatter.string(from: date)
    return (amzDate, String(amzDate.prefix(8)))
}

func signedRequest(
    config: RuntimeConfig,
    method: String,
    path: String,
    query: [[String]] = [],
    payloadHash: String = emptyPayloadHash,
    additionalHeaders: [String: String] = [:]
) throws -> URLRequest {
    guard let endpoint = URL(string: config.endpoint), let host = endpoint.host else {
        throw ConformanceError.assertion("invalid endpoint")
    }
    let authority = endpoint.port.map { "\(host):\($0)" } ?? host
    let time = timestamps(Date())
    var signedHeaders: [String: String] = [
        "host": authority,
        "x-amz-content-sha256": payloadHash,
        "x-amz-date": time.amzDate,
    ]
    for (name, value) in additionalHeaders where name.lowercased().hasPrefix("x-amz-") {
        signedHeaders[name.lowercased()] = value
    }
    let names = signedHeaders.keys.sorted()
    let canonicalHeaders = names.map {
        "\($0):\(normalizedHeaderValue(signedHeaders[$0]!))\n"
    }.joined()
    let signedHeaderNames = names.joined(separator: ";")
    let queryString = canonicalQuery(query)
    let requestValue = [
        method,
        canonicalPath(path),
        queryString,
        canonicalHeaders,
        signedHeaderNames,
        payloadHash,
    ].joined(separator: "\n")
    let scope = "\(time.scopeDate)/\(config.region)/s3/aws4_request"
    let stringToSign = [
        "AWS4-HMAC-SHA256",
        time.amzDate,
        scope,
        sha256Hex(requestValue),
    ].joined(separator: "\n")
    let signature = calculateSignature(
        secretKey: config.secretKey,
        scopeDate: time.scopeDate,
        region: config.region,
        service: "s3",
        stringToSign: stringToSign
    )
    let base = config.endpoint.hasSuffix("/") ? String(config.endpoint.dropLast()) : config.endpoint
    guard let url = URL(string: "\(base)\(canonicalPath(path))\(queryString.isEmpty ? "" : "?\(queryString)")") else {
        throw ConformanceError.assertion("invalid request URL")
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    for (name, value) in additionalHeaders { request.setValue(value, forHTTPHeaderField: name) }
    request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
    request.setValue(time.amzDate, forHTTPHeaderField: "x-amz-date")
    request.setValue(
        "AWS4-HMAC-SHA256 Credential=\(config.accessKey)/\(scope),SignedHeaders=\(signedHeaderNames),Signature=\(signature)",
        forHTTPHeaderField: "Authorization"
    )
    return request
}
