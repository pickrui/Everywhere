//
//  CloudAccountStore.swift
//  Everywhere
//
//  oixCloud account state machine, ported from FlClash
//  lib/providers/cloud_account_provider.dart. The managed mihomo
//  config fetched from the API is the only configuration this
//  client ever runs — there is no manual import path.
//

import Combine
import Foundation
import Security

struct SubscriptionInfo: Equatable {
    var upload: Int64 = 0
    var download: Int64 = 0
    var total: Int64 = 0
    var expire: Int64 = 0

    /// Parses `upload=0;download=100;total=500;expire=1735689600`.
    static func parse(_ info: String?) -> SubscriptionInfo? {
        guard let info, !info.isEmpty else { return nil }
        var result = SubscriptionInfo()
        for field in info.split(separator: ";") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Int64(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            switch parts[0].trimmingCharacters(in: .whitespaces) {
            case "upload": result.upload = value
            case "download": result.download = value
            case "total": result.total = value
            case "expire": result.expire = value
            default: break
            }
        }
        return result
    }
}

@MainActor
final class CloudAccountStore: ObservableObject {
    static let shared = CloudAccountStore()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSyncing = false
    @Published private(set) var profile: CloudProfile?
    @Published private(set) var announcement: CloudNotification?
    @Published private(set) var subscriptionInfo: SubscriptionInfo?
    @Published private(set) var lastSyncDate: Date?
    @Published var lastError: String?

    private var lastRefreshTime: Date?

    private static let profileCacheKey = "cloudProfileCache"
    private static let announcementCacheKey = "cloudAnnouncementCache"
    private static let subscriptionInfoKey = "cloudSubscriptionInfo"
    private static let lastSyncKey = "cloudLastSync"

    private init() {
        restore()
    }

    // MARK: - Restore cached session

    private func restore() {
        guard let token = Keychain.readToken(), !token.isEmpty else { return }
        CloudAPI.shared.setToken(token)
        isLoggedIn = true

        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.profileCacheKey),
           let cached = try? JSONDecoder().decode(CloudProfile.self, from: data) {
            profile = cached
        }
        if let data = defaults.data(forKey: Self.announcementCacheKey),
           let cached = try? JSONDecoder().decode(CloudNotification.self, from: data) {
            announcement = cached
        }
        subscriptionInfo = SubscriptionInfo.parse(defaults.string(forKey: Self.subscriptionInfoKey))
        lastSyncDate = defaults.object(forKey: Self.lastSyncKey) as? Date
    }

    // MARK: - Sign in / out

    func signIn(email: String, password: String) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        lastError = nil
        do {
            let result = try await CloudAPI.shared.login(email: email, password: password)
            try await completeSignIn(
                token: result.token,
                profile: result.profile,
                announcement: result.announcement
            )
        } catch {
            rollbackFailedSignIn(error)
        }
    }

    func signIn(token rawToken: String) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        lastError = nil
        do {
            guard let token = CloudAPI.normalizeToken(rawToken) else {
                throw CloudAPIError.invalidResponse(String(localized: "Access token is empty"))
            }
            CloudAPI.shared.setToken(token)
            let result = try await CloudAPI.shared.getUserInfo()
            try await completeSignIn(
                token: token,
                profile: result.profile,
                announcement: result.announcement
            )
        } catch {
            rollbackFailedSignIn(error)
        }
    }

    func signOut() {
        resetSession(removeManagedConfig: true)
        lastError = nil
    }

    private func handleUnauthorized() {
        signOut()
        lastError = String(localized: "Session expired. Please sign in again.")
    }

    private func rollbackFailedSignIn(_ error: Error) {
        resetSession(removeManagedConfig: false)
        lastError = error.localizedDescription
    }

    private func resetSession(removeManagedConfig: Bool) {
        lastRefreshTime = nil
        Keychain.deleteToken()
        CloudAPI.shared.setToken(nil)
        clearCache()
        OixParamsStorage.clear()
        if removeManagedConfig {
            ConfigurationStore.shared.removeManaged()
        }
        profile = nil
        announcement = nil
        subscriptionInfo = nil
        lastSyncDate = nil
        isLoading = false
        isRefreshing = false
        isSyncing = false
        isLoggedIn = false
    }

    private func completeSignIn(
        token: String,
        profile: CloudProfile,
        announcement: CloudNotification?
    ) async throws {
        guard let normalizedToken = CloudAPI.normalizeToken(token) else {
            throw CloudAPIError.invalidResponse(String(localized: "Access token is empty"))
        }
        CloudAPI.shared.setToken(normalizedToken)
        try Keychain.writeToken(normalizedToken)
        lastRefreshTime = Date()
        cacheProfile(profile, announcement: announcement)
        self.profile = profile
        self.announcement = announcement
        isLoggedIn = true
        injectDefaultParams(for: profile)
        await syncManagedConfig()
    }

    // MARK: - Profile refresh

    func refreshProfile(force: Bool = false) async {
        guard isLoggedIn else { return }
        if !force, let last = lastRefreshTime, Date().timeIntervalSince(last) < 30 * 60 {
            return
        }
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }
        do {
            let oldSubscription = profile?.subscription
            let result = try await CloudAPI.shared.getUserInfo()
            lastRefreshTime = Date()
            cacheProfile(result.profile, announcement: result.announcement ?? announcement)
            profile = result.profile
            if let ann = result.announcement { announcement = ann }
            if let oldSubscription, oldSubscription != result.profile.subscription {
                injectDefaultParams(for: result.profile)
            }
        } catch let error as CloudAPIError where isUnauthorized(error) {
            handleUnauthorized()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Managed config sync

    /// Downloads the managed mihomo config with the user's current
    /// OixParams and stores it as the single Configuration row.
    func syncManagedConfig() async {
        guard isLoggedIn else { return }
        guard !isSyncing else { return }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }
        do {
            if let profile {
                injectDefaultParams(for: profile)
            }
            let params = OixParamsStorage.load()
            let result = try await CloudAPI.shared.fetchManagedConfig(
                paramString: params.encodeWithTfo()
            )
            guard let yaml = String(data: result.config, encoding: .utf8) else {
                throw CloudAPIError.invalidResponse(String(localized: "Server returned invalid config"))
            }
            ConfigurationStore.shared.upsertManaged(content: yaml)
            subscriptionInfo = SubscriptionInfo.parse(result.userinfo)
            lastSyncDate = Date()
            let defaults = UserDefaults.standard
            defaults.set(result.userinfo, forKey: Self.subscriptionInfoKey)
            defaults.set(lastSyncDate, forKey: Self.lastSyncKey)
        } catch let error as CloudAPIError where isUnauthorized(error) {
            handleUnauthorized()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - OixParams

    /// Mirrors FlClash's `_injectDefaultParams`: keeps the stored params
    /// in sync with the tier defaults, auto-upgrading params the user
    /// never customized.
    private func injectDefaultParams(for profile: CloudProfile) {
        let tier = SubscriptionTier.fromServer(profile.subscription)
        let newDefault = tier.defaultParams

        let oldDefaultRaw = OixParamsStorage.loadDefaultRaw()
        let hasUserParams = OixParamsStorage.hasConfig()
        let userParams = OixParamsStorage.load()

        var effective = userParams

        let newDefaultEncoded = newDefault.encode()
        if oldDefaultRaw != newDefaultEncoded {
            OixParamsStorage.saveDefaultRaw(newDefaultEncoded)
        }

        if !hasUserParams
            || (userParams.encodeDefaultComparable() == oldDefaultRaw
                && oldDefaultRaw != newDefaultEncoded) {
            effective = newDefault
        }

        effective = effective.stripEmergencyIfUnsupported(tier)
        if effective.tfo == nil { effective.tfo = true }

        if !hasUserParams || effective != userParams {
            OixParamsStorage.save(effective)
        }
    }

    /// Updates routing params from the account UI and re-syncs.
    func updateParams(_ params: OixParams) {
        OixParamsStorage.save(params)
        objectWillChange.send()
        Task { await syncManagedConfig() }
    }

    func updateEditableOptions(_ raw: String) {
        let current = currentParams
        var edited = OixParams.parse(raw)
        edited.tfo = current.tfo ?? true
        edited.simplerules = current.simplerules
        updateParams(edited)
    }

    var currentParams: OixParams { OixParamsStorage.load() }

    // MARK: - Helpers

    private func isUnauthorized(_ error: CloudAPIError) -> Bool {
        if case .unauthorized = error { return true }
        return false
    }

    private func cacheProfile(_ profile: CloudProfile, announcement: CloudNotification?) {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: Self.profileCacheKey)
        }
        if let announcement, let data = try? JSONEncoder().encode(announcement) {
            defaults.set(data, forKey: Self.announcementCacheKey)
        }
    }

    private func clearCache() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.profileCacheKey)
        defaults.removeObject(forKey: Self.announcementCacheKey)
        defaults.removeObject(forKey: Self.subscriptionInfoKey)
        defaults.removeObject(forKey: Self.lastSyncKey)
    }
}

// MARK: - Keychain token storage

private enum Keychain {
    private static let service = "\(EVCore.Identifier.bundle).oixCloud"
    private static let account = "cloud_token"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func readToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func writeToken(_ token: String) throws {
        let data = Data(token.utf8)
        var query = baseQuery
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound {
            throw CloudAPIError.server(String(localized: "Failed to save access token"))
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw CloudAPIError.server(String(localized: "Failed to save access token"))
        }
    }

    static func deleteToken() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
