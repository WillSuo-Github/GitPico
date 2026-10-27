import AppKit
import Foundation
import Testing
@testable import GitPico

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_NATIVE_XCODE_TESTS"] == "1", "Requires the native Xcode test host."))
@MainActor func nativeXcodeTestHostSuppressesWindowsAndUsesActualBundleMetadata() {
    #expect(ProcessInfo.processInfo.arguments.contains("--background-testing"))
    #expect(NSApplication.shared.activationPolicy() == .prohibited)
    #expect(!NSApplication.shared.isActive)
    #expect(NSApplication.shared.windows.filter(\.isVisible).isEmpty)
    #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "0.0.1")
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    #expect(build.count == 14 && build.allSatisfy(\.isNumber))
    #expect(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String == "26.0")
}
