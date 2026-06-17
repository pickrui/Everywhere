//
//  OixParams.swift
//  Everywhere
//
//  Ported from FlClash lib/models/oix_params.dart.
//

import Foundation

enum SubscriptionTier {
    case none
    case bronze
    case premium

    static func fromServer(_ raw: String?) -> SubscriptionTier {
        let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if s.isEmpty || s == "null" || s == "Pass Iron" { return .none }
        if s == "Pass Bronze" { return .bronze }
        return .premium
    }

    var canUseEmergency: Bool { self == .premium }

    var defaultParams: OixParams {
        switch self {
        case .none: return OixParams()
        case .bronze: return OixParams(level: .emergency)
        case .premium: return OixParams(type: "love")
        }
    }
}

enum NetworkLevel: String {
    case overseas = "1"
    case emergency = "2"
}

struct OixParams: Equatable {
    var level: NetworkLevel?
    var type: String?
    var tfo: Bool?
    var simplerules: Bool
    var extras: [String: String]

    init(
        level: NetworkLevel? = nil,
        type: String? = nil,
        tfo: Bool? = nil,
        simplerules: Bool = false,
        extras: [String: String] = [:]
    ) {
        self.level = level
        self.type = type
        self.tfo = tfo
        self.simplerules = simplerules
        self.extras = extras
    }

    static func parse(_ raw: String) -> OixParams {
        let cleaned = raw.hasPrefix("&") ? String(raw.dropFirst()) : raw
        if cleaned.isEmpty { return OixParams() }

        var level: NetworkLevel?
        var type: String?
        var tfo: Bool?
        var simplerules = false
        var extras: [String: String] = [:]

        for pair in cleaned.split(separator: "&", omittingEmptySubsequences: true) {
            guard let eq = pair.firstIndex(of: "=") else {
                extras[String(pair)] = ""
                continue
            }
            let k = String(pair[..<eq])
            let v = String(pair[pair.index(after: eq)...])
            switch k {
            case "lv":
                if let lv = NetworkLevel(rawValue: v) {
                    level = lv
                } else {
                    extras[k] = v
                }
            case "type":
                type = v
            case "tfo":
                if v == "true" { tfo = true }
                if v == "false" { tfo = false }
            case "simplerules":
                simplerules = (v == "true")
            default:
                extras[k] = v
            }
        }

        return OixParams(level: level, type: type, tfo: tfo, simplerules: simplerules, extras: extras)
    }

    func encode() -> String {
        var segments: [String] = []
        if let level { segments.append("lv=\(level.rawValue)") }
        if let type, !type.isEmpty { segments.append("type=\(type)") }
        if let tfo { segments.append("tfo=\(tfo)") }
        if simplerules { segments.append("simplerules=true") }
        for (k, v) in extras.sorted(by: { $0.key < $1.key }) {
            if k.isEmpty { continue }
            segments.append(v.isEmpty ? k : "\(k)=\(v)")
        }
        if segments.isEmpty { return "" }
        return "&" + segments.joined(separator: "&")
    }

    /// URL-suffix form guaranteed to include a `tfo` segment (defaults to true).
    func encodeWithTfo() -> String {
        var copy = self
        if copy.tfo == nil { copy.tfo = true }
        return copy.encode()
    }

    /// Encoded form excluding independent switches. Used to compare with tier
    /// defaults, which only own routing params like level/type.
    func encodeDefaultComparable() -> String {
        var copy = self
        copy.tfo = nil
        copy.simplerules = false
        return copy.encode()
    }

    func encodeEditableOptions() -> String {
        encodeDefaultComparable()
    }

    /// Strip emergency mode if the current tier cannot support it.
    func stripEmergencyIfUnsupported(_ tier: SubscriptionTier) -> OixParams {
        if level == .emergency, !tier.canUseEmergency, tier != .bronze {
            var copy = self
            copy.level = nil
            return copy
        }
        return self
    }
}

/// Persists the user's oixCloud routing params plus the last tier default
/// they were compared against, mirroring FlClash's OixParamsStorage.
enum OixParamsStorage {
    private static let paramsKey = "oixParams"
    private static let defaultRawKey = "oixParamsDefaultRaw"
    private static let defaults = UserDefaults.standard

    static func hasConfig() -> Bool {
        defaults.string(forKey: paramsKey) != nil
    }

    static func load() -> OixParams {
        OixParams.parse(defaults.string(forKey: paramsKey) ?? "")
    }

    static func save(_ params: OixParams) {
        defaults.set(params.encode(), forKey: paramsKey)
    }

    static func loadDefaultRaw() -> String {
        defaults.string(forKey: defaultRawKey) ?? ""
    }

    static func saveDefaultRaw(_ raw: String) {
        defaults.set(raw, forKey: defaultRawKey)
    }

    static func clear() {
        defaults.removeObject(forKey: paramsKey)
        defaults.removeObject(forKey: defaultRawKey)
    }
}
