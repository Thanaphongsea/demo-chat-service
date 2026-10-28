import SwiftUI

struct AsyncStateView: View {
  let title: String
  let systemImage: String
  let message: String
  let identifier: String
  var retry: (() -> Void)?

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage).accessibilityIdentifier(identifier)
    } description: {
      Text(message)
    } actions: {
      if let retry {
        Button("Try again", action: retry)
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("conversations.retry")
      }
    }
  }
}
