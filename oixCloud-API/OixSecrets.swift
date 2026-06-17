//
//  OixSecrets.swift
//  Everywhere
//
//  oixCloud endpoints and app secret, read from Info.plist keys that
//  are injected at build time from Config/Secrets.local.xcconfig —
//  the Xcode equivalent of FlClash's `--dart-define-from-file=.env.local`.
//

import Foundation

enum OixSecrets {
    static let siteDomain = value(for: "OixBaseDomain")
    static let spareSiteDomain = optionalValue(for: "OixSpareDomain")
    static let primaryApiDomain = value(for: "OixApiDomain")
    static let spareApiDomain = value(for: "OixSpareApiDomain")
    static let appSecret = value(for: "OixAppSecret")
    static let profileKey = value(for: "OixProfileKey")
    static let userAgent = "Everywhere for oixCloud"

    static var apiDomains: [String] {
        var domains: [String] = []
        for domain in [primaryApiDomain, spareApiDomain] {
            let normalized = domain.trimmingCharacters(in: .whitespaces).lowercased()
            if !normalized.isEmpty, !domains.contains(normalized) {
                domains.append(normalized)
            }
        }
        return domains
    }

    private static func value(for key: String) -> String {
        guard let resolved = optionalValue(for: key) else {
            preconditionFailure("Missing \(key) — fill in Config/Secrets.local.xcconfig")
        }
        return resolved
    }

    private static func optionalValue(for key: String) -> String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("$(") { return nil }
        return trimmed
    }
}
