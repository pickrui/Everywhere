//
//  CloudLoginView.swift
//  Everywhere
//
//  Access-token or email/password sign-in for oixCloud, mirroring
//  FlClash's cloud_login_page.
//

import SwiftUI

struct CloudLoginView: View {
    @ObservedObject private var account = CloudAccountStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mode: LoginMode = .token
    @State private var token = ""
    @State private var email = ""
    @State private var password = ""
    @State private var revealToken = false
    @State private var revealPassword = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case token
        case email
        case password
    }

    private enum LoginMode: String, CaseIterable, Identifiable {
        case token
        case emailPassword

        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                Picker("Login Method", selection: $mode) {
                    Text("Access Token").tag(LoginMode.token)
                    Text("Email & Password").tag(LoginMode.emailPassword)
                }
                .pickerStyle(.segmented)
                .disabled(account.isLoading)

                CloudCard {
                    VStack(spacing: 12) {
                        switch mode {
                        case .token:
                            secretField(
                                title: "Access Token",
                                text: $token,
                                revealed: $revealToken,
                                field: .token,
                                submitLabel: .go
                            )
                        case .emailPassword:
                            TextField("Email", text: $email)
                                .keyboardType(.emailAddress)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .email)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
                                .textFieldStyle(.roundedBorder)
                            secretField(
                                title: "Password",
                                text: $password,
                                revealed: $revealPassword,
                                field: .password,
                                submitLabel: .go
                            )
                        }

                        if let error = account.lastError {
                            Text(error)
                                .font(.footnote)
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                Button {
                    submit()
                } label: {
                    if account.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Sign In")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSubmit)
            }
            .padding(20)
            .frame(maxWidth: 520)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Sign In")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(account.isLoading)
        .onChange(of: account.isLoggedIn) { loggedIn in
            if loggedIn {
                Task { @MainActor in
                    await Task.yield()
                    dismiss()
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 64, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
            Text("oixCloud Account")
                .font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    private func secretField(
        title: LocalizedStringKey,
        text: Binding<String>,
        revealed: Binding<Bool>,
        field: Field,
        submitLabel: SubmitLabel
    ) -> some View {
        HStack(spacing: 8) {
            Group {
                if revealed.wrappedValue {
                    TextField(title, text: text)
                } else {
                    SecureField(title, text: text)
                }
            }
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focusedField, equals: field)
            .submitLabel(submitLabel)
            .onSubmit { submit() }

            Button {
                revealed.wrappedValue.toggle()
            } label: {
                Image(systemName: revealed.wrappedValue ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    private var canSubmit: Bool {
        guard !account.isLoading else { return false }
        switch mode {
        case .token:
            return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .emailPassword:
            guard !password.isEmpty else { return false }
            let trimmed = email.trimmingCharacters(in: .whitespaces)
            return trimmed.contains("@") && trimmed.contains(".")
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focusedField = nil
        Task {
            switch mode {
            case .token:
                await account.signIn(
                    token: token.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            case .emailPassword:
                await account.signIn(
                    email: email.trimmingCharacters(in: .whitespaces),
                    password: password
                )
            }
        }
    }
}

private struct CloudCard<Content: View>: View {
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
