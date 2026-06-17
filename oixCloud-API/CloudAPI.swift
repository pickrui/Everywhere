//
//  CloudAPI.swift
//  Everywhere
//
//  oixCloud REST client, ported from FlClash lib/services/cloud_api_service.dart.
//  Endpoints: POST /api/v1/login, POST /api/v1/information,
//  GET /api/v1/managed/flclash/direct (HMAC-signed).
//

import CryptoKit
import Foundation

struct CloudProfile: Codable, Equatable {
    var subscription: String
    var expireTime: Date
    var todayUsed: String
    var totalUsed: String
    var totalTraffic: String
    var usageProgress: Double
    var remaining: String
    var balance: String
    var commission: String
    var points: String
}

struct CloudNotification: Codable, Equatable {
    var message: String
    var publishTime: Date
}

enum CloudAPIError: LocalizedError {
    case unauthorized
    case server(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Unauthorized")
        case .server(let m), .invalidResponse(let m):
            return m
        }
    }
}

final class CloudAPI {
    static let shared = CloudAPI()

    private(set) var token: String?

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = [
            "User-Agent": OixSecrets.userAgent,
            "Accept": "application/json",
        ]
        // The oixCloud API must stay reachable when the proxy is broken,
        // so never route it through the connection proxy settings.
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config)
    }

    // MARK: - Token

    static func normalizeToken(_ token: String?) -> String? {
        guard var normalized = token?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        normalized = stripWrappingQuotes(normalized)
        if normalized.lowercased().hasPrefix("bearer ") {
            normalized = String(normalized.dropFirst("bearer ".count))
                .trimmingCharacters(in: .whitespaces)
        }
        normalized = stripWrappingQuotes(normalized)
        return normalized.isEmpty ? nil : normalized
    }

    private static func stripWrappingQuotes(_ value: String) -> String {
        var normalized = value
        while normalized.count >= 2,
              (normalized.hasPrefix("\"") && normalized.hasSuffix("\""))
              || (normalized.hasPrefix("'") && normalized.hasSuffix("'")) {
            normalized = String(normalized.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
        }
        return normalized
    }

    func setToken(_ token: String?) {
        self.token = Self.normalizeToken(token)
    }

    // MARK: - Endpoints

    func login(email: String, password: String) async throws
        -> (token: String, profile: CloudProfile, announcement: CloudNotification?) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in [("email", email), ("passwd", password), ("token_expire", "365")] {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        let json = try await request(
            path: "/api/v1/login",
            method: "POST",
            headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"],
            body: body,
            authorized: false
        )

        guard let ret = json["ret"] as? Int, ret == 200,
              let data = json["data"] as? [String: Any] else {
            throw CloudAPIError.server((json["msg"] as? String) ?? String(localized: "Login failed"))
        }
        guard let tokenStr = data["token"] as? String, !tokenStr.isEmpty else {
            throw CloudAPIError.invalidResponse(String(localized: "API returned empty token"))
        }

        setToken(tokenStr)
        let parsed = try Self.parseUserInfo(data)
        return (tokenStr, parsed.profile, parsed.announcement)
    }

    func getUserInfo() async throws -> (profile: CloudProfile, announcement: CloudNotification?) {
        guard token?.isEmpty == false else { throw CloudAPIError.unauthorized }

        let json = try await request(path: "/api/v1/information", method: "POST")

        guard let ret = json["ret"] as? Int, ret == 200,
              let data = json["data"] as? [String: Any] else {
            if (json["ret"] as? Int) == 401 {
                setToken(nil)
                throw CloudAPIError.unauthorized
            }
            throw CloudAPIError.server((json["msg"] as? String) ?? String(localized: "Failed to parse user info"))
        }
        return try Self.parseUserInfo(data)
    }

    func checkServiceHealth() async throws {
        var components = URLComponents()
        components.scheme = "https"
        components.host = OixSecrets.primaryApiDomain
        components.path = "/check"
        guard let url = components.url else {
            throw CloudAPIError.invalidResponse(String(localized: "Invalid response"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudAPIError.invalidResponse(String(localized: "Invalid response"))
        }
        guard http.statusCode == 200 else {
            throw CloudAPIError.server(
                String(format: String(localized: "Server returned HTTP %lld"), http.statusCode)
            )
        }
    }

    /// Fetches the managed mihomo config. `paramString` is the
    /// `OixParams.encodeWithTfo()` output (leading `&` allowed).
    /// Returns the decoded YAML bytes plus the subscription-userinfo string.
    func fetchManagedConfig(paramString: String) async throws -> (config: Data, userinfo: String?) {
        var queryItems: [URLQueryItem] = []
        let cleaned = paramString.hasPrefix("&") ? String(paramString.dropFirst()) : paramString
        for pair in cleaned.split(separator: "&", omittingEmptySubsequences: true) {
            if let eq = pair.firstIndex(of: "=") {
                queryItems.append(URLQueryItem(
                    name: String(pair[..<eq]),
                    value: String(pair[pair.index(after: eq)...])
                ))
            } else {
                queryItems.append(URLQueryItem(name: String(pair), value: nil))
            }
        }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let signature = Self.hmacSHA256Hex(message: timestamp, key: OixSecrets.appSecret)
        var headers = [
            "X-Flclash-Timestamp": timestamp,
            "X-Flclash-Signature": signature,
        ]
        let buildNumber = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""
        if !buildNumber.isEmpty {
            headers["X-Flclash-Build"] = buildNumber
            queryItems.append(URLQueryItem(name: "flclash_build", value: buildNumber))
        }

        let json = try await request(
            path: "/api/v1/managed/flclash/direct",
            method: "GET",
            queryItems: queryItems,
            headers: headers
        )

        if (json["ret"] as? Int) == 401 {
            setToken(nil)
            throw CloudAPIError.unauthorized
        }
        guard let configB64 = json["config"] as? String, !configB64.isEmpty else {
            throw CloudAPIError.invalidResponse(String(localized: "Server returned empty config"))
        }
        guard let payload = Self.decodeBase64(configB64) else {
            throw CloudAPIError.invalidResponse(String(localized: "Server returned invalid config"))
        }
        let config: Data
        if Self.isFlclashEncrypted(payload) {
            guard let decrypted = Self.decryptFlclashPayload(payload, profileKey: OixSecrets.profileKey) else {
                throw CloudAPIError.invalidResponse(String(localized: "Server returned invalid config"))
            }
            config = decrypted
        } else {
            config = payload
        }
        return (config, json["userinfo"] as? String)
    }

    // MARK: - Transport

    /// One attempt per API domain (primary, then spare) for
    /// connection-level failures; HTTP responses are never retried
    /// on the spare endpoint except 5xx.
    private func request(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        authorized: Bool = true
    ) async throws -> [String: Any] {
        var lastError: Error = CloudAPIError.server(String(localized: "Connection failed"))

        for domain in OixSecrets.apiDomains {
            var components = URLComponents()
            components.scheme = "https"
            components.host = domain
            components.path = path
            if !queryItems.isEmpty { components.queryItems = queryItems }
            guard let url = components.url else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            if authorized, let token, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw CloudAPIError.invalidResponse(String(localized: "Invalid response"))
                }
                if http.statusCode == 401 {
                    setToken(nil)
                    throw CloudAPIError.unauthorized
                }
                if http.statusCode >= 500 {
                    lastError = CloudAPIError.server(
                        String(format: String(localized: "Server returned HTTP %lld"), http.statusCode)
                    )
                    continue
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CloudAPIError.invalidResponse(String(localized: "Invalid response format"))
                }
                return json
            } catch let error as CloudAPIError {
                throw error
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    // MARK: - Parsing

    static func hmacSHA256Hex(message: String, key: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: Data(key.utf8))
        )
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    static func decodeBase64(_ string: String) -> Data? {
        var normalized = string.components(separatedBy: .whitespacesAndNewlines).joined()
        normalized = normalized
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }

    private static let flclashPayloadMagic: [UInt8] = [0x46, 0x4C, 0x45, 0x4E]
    private static let flclashNonceLength = 12
    private static let flclashTagLength = 16
    private static let flclashHeaderLength = 5

    static func isFlclashEncrypted(_ data: Data) -> Bool {
        guard data.count >= flclashHeaderLength else { return false }
        return Array(data.prefix(4)) == flclashPayloadMagic
    }

    static func decryptFlclashPayload(_ data: Data, profileKey: String) -> Data? {
        let minimum = flclashHeaderLength + flclashNonceLength + flclashTagLength
        guard data.count > minimum, isFlclashEncrypted(data) else { return nil }
        let bytes = [UInt8](data)
        let nonceStart = flclashHeaderLength
        let nonceEnd = nonceStart + flclashNonceLength
        let tagStart = bytes.count - flclashTagLength
        let nonceData = Data(bytes[nonceStart..<nonceEnd])
        let cipherData = Data(bytes[nonceEnd..<tagStart])
        let tagData = Data(bytes[tagStart..<bytes.count])
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(profileKey.utf8))))
        guard let nonce = try? AES.GCM.Nonce(data: nonceData),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherData, tag: tagData),
              let plaintext = try? AES.GCM.open(box, using: key) else {
            return nil
        }
        return plaintext
    }

    static func parseUserInfo(_ info: [String: Any]) throws
        -> (profile: CloudProfile, announcement: CloudNotification?) {
        let requiredKeys = [
            "plan", "plan_time", "used", "traffic", "today_used",
            "unused", "money", "aff_money", "integral",
        ]
        for key in requiredKeys where info.index(forKey: key) == nil {
            throw CloudAPIError.invalidResponse("Missing required field: \(key)")
        }

        func str(_ key: String, defaultValue: String) -> String {
            if let s = info[key] as? String { return s }
            if let n = info[key] as? NSNumber { return n.stringValue }
            return defaultValue
        }

        var announcement: CloudNotification?
        if let ann = info["announcement"] as? [String: Any] {
            let formatter = ISO8601DateFormatter()
            announcement = CloudNotification(
                message: (ann["content"] as? String) ?? "",
                publishTime: formatter.date(from: (ann["date"] as? String) ?? "") ?? Date()
            )
        }

        let expireTime = parseServerDate(str("plan_time", defaultValue: "")) ?? Date()

        let usedBytes = (try? parseTraffic(str("used", defaultValue: ""))) ?? 0
        let totalBytes = (try? parseTraffic(str("traffic", defaultValue: ""))) ?? 0
        let progress = totalBytes > 0 ? min(max(Double(usedBytes) / Double(totalBytes), 0), 1) : 0

        let profile = CloudProfile(
            subscription: str("plan", defaultValue: "Default"),
            expireTime: expireTime,
            todayUsed: str("today_used", defaultValue: "0"),
            totalUsed: str("used", defaultValue: "0"),
            totalTraffic: str("traffic", defaultValue: "0"),
            usageProgress: progress,
            remaining: str("unused", defaultValue: "0"),
            balance: str("money", defaultValue: "0.00"),
            commission: str("aff_money", defaultValue: "0.00"),
            points: str("integral", defaultValue: "50 / 50")
        )
        return (profile, announcement)
    }

    static func parseServerDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return plain.date(from: value)
    }

    /// Parses a human traffic string ("1.5 GB", "200 MiB", "42") into bytes.
    /// Multipliers always follow the 1024 convention regardless of whether
    /// the unit is written `MB` or `MiB` — the server uses both forms.
    static func parseTraffic(_ value: String) throws -> Int64 {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        let pattern = #"^(\d+(?:\.\d+)?)\s*([KMGTkmgt])?(i|I)?[bB]?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
              ) else {
            throw CloudAPIError.invalidResponse("Invalid traffic format: \(value)")
        }
        func group(_ idx: Int) -> String? {
            guard let r = Range(match.range(at: idx), in: trimmed) else { return nil }
            return String(trimmed[r])
        }
        let number = Double(group(1) ?? "0") ?? 0
        let multiplier: Double
        switch group(2)?.uppercased() {
        case "T": multiplier = 1_099_511_627_776
        case "G": multiplier = 1_073_741_824
        case "M": multiplier = 1_048_576
        case "K": multiplier = 1024
        default: multiplier = 1
        }
        return Int64((number * multiplier).rounded())
    }
}
