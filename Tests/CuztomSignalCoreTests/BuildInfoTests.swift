import Testing
@testable import CuztomSignalCore

@Test func buildInfoFormatsVersionAndBuildNumber() {
    #expect(BuildInfo.displayTag(shortVersion: "1.2.3", buildNumber: "42") == "Build 1.2.3 (42)")
    #expect(BuildInfo.displayTag(shortVersion: "1.2.3", buildNumber: "1.2.3") == "Build 1.2.3")
    #expect(BuildInfo.displayTag(shortVersion: "  ", buildNumber: nil) == "Build dev")
    #expect(BuildInfo.displayTag(environment: ["CUZTOM_SIGNAL_BUILD_TAG": "ci-123"]) == "Build ci-123")
}
