import AuthenticationServices
import CryptoKit
import Supabase
import SwiftUI

struct SignInView: View {
    @Environment(AppState.self) private var app
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var nonce = ""
    @FocusState private var focus: Field?

    enum Field { case email, code }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MegaTitle(lines: ["GAME", "NITE"])
                    .padding(.top, 36)
                Text("Real-world games with your city. Sign in to join tonight's game.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.muted)

                if !AppConfig.isConfigured {
                    Text("This build isn't connected to a server yet.")
                        .font(.footnote)
                        .foregroundStyle(Theme.warn)
                        .panel()
                }

                SignInWithAppleButton(.signIn) { request in
                    nonce = Self.randomNonce()
                    request.requestedScopes = [.fullName]
                    request.nonce = Self.sha256(nonce)
                } onCompletion: { result in
                    Task { await handleApple(result) }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(busy || !AppConfig.isConfigured)

                HStack {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    Text("or use email").font(.footnote).foregroundStyle(Theme.muted)
                    Rectangle().fill(Theme.line).frame(height: 1)
                }

                VStack(alignment: .leading, spacing: 10) {
                    if !codeSent {
                        TextField("", text: $email, prompt: Text(verbatim: "you@example.com").foregroundStyle(Theme.muted))
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .email)
                            .fieldStyle(focused: focus == .email)
                            .submitLabel(.send)
                            .onSubmit { Task { await sendCode() } }
                        Button("Email me a code") { Task { await sendCode() } }
                            .buttonStyle(.secondary)
                            .disabled(busy || !email.contains("@") || !AppConfig.isConfigured)
                    } else {
                        Text("Enter the 6-digit code we sent to \(email).")
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                        TextField("", text: $code, prompt: Text("123456").foregroundStyle(Theme.muted))
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .focused($focus, equals: .code)
                            .fieldStyle(focused: focus == .code)
                        Button("Sign in") { Task { await verify() } }
                            .buttonStyle(.cta)
                            .disabled(busy || code.count < 6)
                        Button("Use a different email") { codeSent = false; code = "" }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.neon)
                    }
                }

                Text("Game Nite is for players 18 and older.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg)
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                app.errorMessage = "Apple didn't return a sign-in token. Try again."
                return
            }
            busy = true
            defer { busy = false }
            do {
                _ = try await supabase.auth.signInWithIdToken(
                    credentials: OpenIDConnectCredentials(provider: .apple, idToken: token, nonce: nonce))
            } catch {
                app.report(error)
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            app.report(error)
        }
    }

    private func sendCode() async {
        busy = true
        defer { busy = false }
        do {
            try await supabase.auth.signInWithOTP(email: email.trimmingCharacters(in: .whitespaces))
            codeSent = true
            focus = .code
        } catch {
            app.report(error)
        }
    }

    private func verify() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await supabase.auth.verifyOTP(
                email: email.trimmingCharacters(in: .whitespaces), token: code, type: .email)
        } catch {
            app.report(error)
        }
    }

    static func randomNonce(length: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars.randomElement(using: &generator)! })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
