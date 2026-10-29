import SwiftUI

@main
struct ChatCallApp: App {
  private let dependencies = AppDependencies.launch()

  var body: some Scene {
    WindowGroup {
      AppRootView(dependencies: dependencies)
        .environment(\.appDependencies, dependencies)
    }
  }
}
