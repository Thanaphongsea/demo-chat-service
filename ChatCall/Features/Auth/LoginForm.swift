import SwiftUI

struct LoginForm: View {
  @Bindable var store: AuthStore

  @State private var passwordIsVisible = false
  @State private var submission: Task<Void, Never>?
  @FocusState private var focusedField: Field?

  private enum Field: Hashable { case username, password }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Username or email").font(.subheadline.weight(.medium))
        TextField("Username or email", text: $store.username)
          .textContentType(.username)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.next)
          .focused($focusedField, equals: .username)
          .onSubmit { focusedField = .password }
          .accessibilityIdentifier("auth.username")
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Password").font(.subheadline.weight(.medium))
        HStack {
          Group {
            if passwordIsVisible {
              TextField("Password", text: $store.password)
            } else {
              SecureField("Password", text: $store.password)
            }
          }
          .textContentType(.password)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .privacySensitive()
          .submitLabel(.go)
          .focused($focusedField, equals: .password)
          .onSubmit(submit)
          .accessibilityIdentifier("auth.password")

          Button {
            passwordIsVisible.toggle()
          } label: {
            Image(systemName: passwordIsVisible ? "eye.slash" : "eye")
              .frame(minWidth: 44, minHeight: 44)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(passwordIsVisible ? "Hide password" : "Show password")
          .accessibilityIdentifier("auth.togglePassword")
        }
      }

      if let message = store.validationMessage {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("auth.validation")
      }

      if case .failed(let message) = store.state {
        Label(message, systemImage: "exclamationmark.circle")
          .font(.callout)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("auth.error")
      }

      Button(action: submit) {
        HStack {
          if store.state == .signingIn {
            ProgressView().accessibilityHidden(true)
          }
          Text(store.state == .signingIn ? "Signing in…" : "Sign in")
            .font(.headline)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(.glassProminent)
      .disabled(!store.canSignIn)
      .accessibilityIdentifier("auth.signIn")
    }
    .textFieldStyle(.roundedBorder)
    .onDisappear {
      submission?.cancel()
      submission = nil
    }
  }

  private func submit() {
    guard store.canSignIn, submission == nil else { return }
    focusedField = nil
    submission = Task {
      await store.signIn()
      submission = nil
    }
  }
}
