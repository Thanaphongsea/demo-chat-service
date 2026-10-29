import Testing

@testable import ChatCall

nonisolated struct CameraPlanTests {
  @Test("Turning the camera off never touches capture; turning it on starts capture only when it is not running")
  func plan() {
    #expect(CameraPlan.make(enabled: false, isCapturing: true) == CameraPlan(needsCapture: false))
    #expect(CameraPlan.make(enabled: false, isCapturing: false) == CameraPlan(needsCapture: false))
    #expect(CameraPlan.make(enabled: true, isCapturing: true) == CameraPlan(needsCapture: false))
    #expect(CameraPlan.make(enabled: true, isCapturing: false) == CameraPlan(needsCapture: true))
  }
}
