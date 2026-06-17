//
//  CloudAccountView.swift
//  Everywhere
//
//  Account dashboard for oixCloud, ported from FlClash
//  lib/views/cloud/cloud_profile_card.dart.
//

import SwiftUI

struct CloudAccountView: View {
    @ObservedObject private var account = CloudAccountStore.shared
    @State private var isCheckingService = false
    @State private var serviceError: String?
    @State private var checkedService = false
    @State private var editableOptions = ""
    @State private var defaultEditableOptions = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if account.isLoggedIn {
                    HStack {
                        Spacer()
                        toolbarActions
                    }
                }

                if account.isLoggedIn, let error = account.lastError, !error.isEmpty {
                    errorCard(error)
                }

                if account.isLoggedIn, let profile = account.profile {
                    profileCard(profile)
                    trafficCard(profile)
                    walletCard(profile)
                    networkCard(profile)
                    if let announcement = account.announcement,
                       !announcement.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        announcementCard(announcement)
                    }
                } else if account.isLoggedIn {
                    loadingCard
                }
            }
            .padding(16)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            if account.isLoggedIn {
                await account.refreshProfile(force: true)
                reloadEditableOptions()
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("oixCloud")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if account.isLoggedIn {
                await account.refreshProfile()
                reloadEditableOptions()
                await checkHealth()
            }
        }
        .onChange(of: account.isLoggedIn) { loggedIn in
            Task { @MainActor in
                await Task.yield()
                if loggedIn {
                    reloadEditableOptions()
                } else {
                    editableOptions = ""
                    defaultEditableOptions = ""
                }
            }
        }
    }

    // MARK: - Cards

    private func errorCard(_ message: String) -> some View {
        AccountCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .frame(width: 24)
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func profileCard(_ profile: CloudProfile) -> some View {
        AccountCard {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 56, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.subscription)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text("Expires: \(profile.expireTime, format: .dateTime.year().month().day())")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                Link(destination: URL(string: "https://\(OixSecrets.siteDomain)/user")!) {
                    Image(systemName: "arrow.up.right")
                        .font(.headline)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(.tertiarySystemGroupedBackground))
                        )
                }
                .accessibilityLabel(Text("Open Account Page"))
            }
        }
    }

    private func trafficCard(_ profile: CloudProfile) -> some View {
        AccountCard {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: "Traffic", systemImage: "chart.bar.fill")
                MetricRow(title: "Today Used", value: profile.todayUsed, systemImage: "calendar")
                ProgressView(value: min(max(profile.usageProgress, 0), 1))
                    .tint(.accentColor)
                HStack {
                    Text(profile.totalUsed)
                    Spacer()
                    Text("Remaining: \(profile.remaining)")
                }
                .font(.footnote)
                .foregroundColor(.secondary)
            }
        }
    }

    private func walletCard(_ profile: CloudProfile) -> some View {
        AccountCard {
            VStack(spacing: 12) {
                MetricRow(title: "Balance", value: profile.balance, systemImage: "creditcard")
                Divider()
                MetricRow(title: "Commission", value: profile.commission, systemImage: "banknote")
                Divider()
                MetricRow(title: "Points", value: profile.points, systemImage: "star")
            }
        }
    }

    private func networkCard(_ profile: CloudProfile) -> some View {
        let tier = SubscriptionTier.fromServer(profile.subscription)
        return AccountCard {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: levelBinding(.overseas, tier: tier)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Overseas Network")
                        Text("Use when connecting from outside mainland China")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(account.isSyncing)

                if tier.canUseEmergency {
                    Divider()
                    Toggle(isOn: levelBinding(.emergency, tier: tier)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Emergency Mode")
                            Text("Use emergency routing when normal lines are unavailable")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(account.isSyncing)
                }

                Divider()
                Toggle(isOn: tfoBinding()) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TCP Fast Open")
                        Text("Enable this option to accelerate TCP connection establishment")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(account.isSyncing)

                Divider()
                Toggle(isOn: simpleRulesBinding()) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Minimal Configuration")
                        Text("Use a simplified rule set to generate a smaller profile")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(account.isSyncing)

                Divider()
                optionalParamsEditor

                if account.isSyncing {
                    Label("Updating config…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var optionalParamsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CardTitle(title: "Optional Parameters", systemImage: "slider.horizontal.3")
                Spacer()
                if editableOptions != defaultEditableOptions {
                    Button {
                        editableOptions = defaultEditableOptions
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Restore Default"))
                    .disabled(account.isSyncing)
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: editableOptionsBinding)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 72, maxHeight: 96)
                    .padding(4)
                    .disabled(account.isSyncing)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(.separator).opacity(0.7), lineWidth: 1)
                    )

                if editableOptions.isEmpty {
                    Text("&area=hk")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }

            HStack {
                Spacer()
                Button("Apply") {
                    applyEditableOptions()
                }
                .buttonStyle(.bordered)
                .disabled(account.isSyncing || normalizedEditableOptions(editableOptions) == account.currentParams.encodeEditableOptions())
            }
        }
    }

    private func announcementCard(_ announcement: CloudNotification) -> some View {
        AccountCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardTitle(title: "Announcement", systemImage: "megaphone.fill")
                    Spacer()
                    Text(announcement.publishTime, format: .dateTime.year().month().day())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(attributedAnnouncement(announcement.message))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var loadingCard: some View {
        AccountCard {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading")
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func attributedAnnouncement(_ message: String) -> AttributedString {
        guard let data = message.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
              ) else {
            return AttributedString(message)
        }
        return AttributedString(attributed)
    }

    // MARK: - Service health

    private var serviceIconName: String {
        if !checkedService { return "questionmark.circle" }
        return serviceError == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var serviceIconColor: Color {
        if !checkedService { return .secondary }
        return serviceError == nil ? .green : .red
    }

    private var serviceStatusLabel: String {
        if isCheckingService || !checkedService { return String(localized: "Check API") }
        return serviceError == nil
            ? String(localized: "API Available")
            : String(localized: "Service check failed")
    }

    private var toolbarActions: some View {
        HStack(spacing: 4) {
            ToolbarIconButton(
                title: "Check API",
                value: serviceStatusLabel,
                disabled: isCheckingService,
                identifier: "oixcloud.check-api"
            ) {
                Task { await checkHealth() }
            } content: {
                serviceStatusIcon
            }

            ToolbarIconButton(
                title: "Sync Config",
                disabled: account.isSyncing,
                identifier: "oixcloud.sync-config"
            ) {
                Task { await account.syncManagedConfig() }
            } content: {
                if account.isSyncing {
                    toolbarProgressView
                } else {
                    Image(systemName: "icloud.and.arrow.down")
                }
            }

            ToolbarIconButton(
                title: "Logout",
                identifier: "oixcloud.logout"
            ) {
                performSignOut()
            } content: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(.separator).opacity(0.25), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
    }

    private func performSignOut() {
        Task { await TunnelManager.shared.setEnabled(false, configuration: nil) }
        account.signOut()
    }

    private var serviceStatusIcon: some View {
        Group {
            if isCheckingService {
                toolbarProgressView
            } else {
                Image(systemName: serviceIconName)
                    .foregroundColor(serviceIconColor)
            }
        }
    }

    private var toolbarProgressView: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: 20, height: 20)
    }

    private func checkHealth() async {
        guard !isCheckingService else { return }
        isCheckingService = true
        serviceError = nil
        do {
            try await CloudAPI.shared.checkServiceHealth()
        } catch {
            serviceError = error.localizedDescription
        }
        checkedService = true
        isCheckingService = false
    }

    // MARK: - Param bindings (mirrors FlClash switch semantics)

    private func levelBinding(_ level: NetworkLevel, tier: SubscriptionTier) -> Binding<Bool> {
        Binding(
            get: { account.currentParams.level == level },
            set: { on in
                var next = account.currentParams
                if on {
                    next.level = level
                    next.type = nil
                } else {
                    let defaults = tier.defaultParams
                    next.level = defaults.level
                    next.type = defaults.type
                }
                account.updateParams(next)
                reloadEditableOptions(from: next)
            }
        )
    }

    private func tfoBinding() -> Binding<Bool> {
        Binding(
            get: { account.currentParams.tfo ?? true },
            set: { on in
                var next = account.currentParams
                next.tfo = on
                account.updateParams(next)
                reloadEditableOptions(from: next)
            }
        )
    }

    private func simpleRulesBinding() -> Binding<Bool> {
        Binding(
            get: { account.currentParams.simplerules },
            set: { on in
                var next = account.currentParams
                next.simplerules = on
                account.updateParams(next)
                reloadEditableOptions(from: next)
            }
        )
    }

    private func reloadEditableOptions(from params: OixParams? = nil) {
        editableOptions = (params ?? account.currentParams).encodeEditableOptions()
        defaultEditableOptions = OixParams.parse(OixParamsStorage.loadDefaultRaw()).encodeEditableOptions()
    }

    private var editableOptionsBinding: Binding<String> {
        Binding(
            get: { editableOptions },
            set: { editableOptions = filterIndependentSwitchParams($0) }
        )
    }

    private func applyEditableOptions() {
        let normalized = normalizedEditableOptions(editableOptions)
        editableOptions = normalized
        account.updateEditableOptions(normalized)
    }

    private func normalizedEditableOptions(_ raw: String) -> String {
        OixParams.parse(filterIndependentSwitchParams(raw)).encodeEditableOptions()
    }

    private func filterIndependentSwitchParams(_ raw: String) -> String {
        raw.split(separator: "&", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { segment in
                let parts = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return true }
                let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !((key == "tfo" || key == "simplerules") && (value == "true" || value == "false"))
            }
            .joined(separator: "&")
    }
}

private struct AccountCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }
}

private struct CardTitle: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.secondary)
    }
}

private struct ToolbarIconButton<Content: View>: View {
    let title: LocalizedStringKey
    let value: String?
    let disabled: Bool
    let identifier: String
    let action: () -> Void
    private let content: Content

    init(
        title: LocalizedStringKey,
        value: String? = nil,
        disabled: Bool = false,
        identifier: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.value = value
        self.disabled = disabled
        self.identifier = identifier
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button {
            guard !disabled else { return }
            action()
        } label: {
            content
                .font(.body)
                .frame(width: 44, height: 44)
        }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .disabled(disabled)
            .opacity(disabled ? 0.45 : 1)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(value ?? ""))
            .accessibilityIdentifier(identifier)
            .accessibilityAddTraits(.isButton)
    }
}

private struct MetricRow: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .multilineTextAlignment(.trailing)
        }
    }
}
