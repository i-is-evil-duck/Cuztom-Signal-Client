import Foundation
import Testing
@testable import CuztomSignalCore

@Test func nativeLoaderDoesNotInferCheckoutPaths() {
    let paths = RustCoreService.defaultSearchPaths()
    let inferredRelease = FileManager.default.currentDirectoryPath
        + "/rust-core/target/release/libcuztom_signal_core.dylib"
    let inferredDebug = FileManager.default.currentDirectoryPath
        + "/rust-core/target/debug/libcuztom_signal_core.dylib"
    #expect(!paths.contains(inferredRelease))
    #expect(!paths.contains(inferredDebug))
    // ABI 3 added core_cmd_http_response, which the SFU bridge needs. ABI 4
    // added the group call proof and the two host derivations. ABI 5 added
    // core_cmd_sfu_http_request, so the SFU's own requests are performed on a
    // client trusted with the service certificate authority. ABI 6 added
    // core_cmd_group_call_set_audio_muted, because RingRTC reads an unset
    // audio-muted heartbeat as muted. A dylib older than
    // those must fail to load rather than load with missing symbols and fail later
    // with a misleading error.
    #expect(RustCoreService.expectedNativeABI == 6)
}
