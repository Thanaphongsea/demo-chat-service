import SwiftUI

@main
struct ChatCallApp: App {
  private let dependencies = AppDependencies.mock()

  var body: some Scene {
    WindowGroup {
      AppRootView(dependencies: dependencies)
        .environment(\.appDependencies, dependencies)
    }
  }
}
