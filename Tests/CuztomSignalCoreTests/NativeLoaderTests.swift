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
    #expect(RustCoreService.expectedNativeABI == 2)
}
