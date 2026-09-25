import Foundation
import Testing
@testable import CuztomSignalCore

/// The native ABI is a contract across three places: the C header, the Rust
/// `CORE_ABI_VERSION`, and the Swift loader that refuses a mismatched dylib.
/// Drift between them does not fail to build; it fails at `dlopen` on a user's
/// machine with a log line about an ABI number.
///
/// These read the checked-in files rather than the constants, so bumping one and
/// forgetting the others is caught here.
/// The app's own group-call wiring.
///
/// The shared `GroupCallController` is built with an `EmptyGroupRoster`, so a
/// controller that is never given the real roster silently reports an empty
/// membership and cannot resolve an inbound group's id. That shipped once: calls
/// were placed with `members-built count=0` and inbound calls were discarded as
/// unresolvable, both of which look like a broken SFU rather than a wiring gap.
@Suite("App group call wiring")
struct GroupCallWiringTests {
    private static func appSource(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("XcodeApp/Sources/\(name)"),
            encoding: .utf8
        )
    }

    @Test func theAppDoesNotUseTheRosterlessSharedController() throws {
        let source = try Self.appSource("CuztomSignalApp.swift")
        // Match a *use* rather than the bare name: prose in a comment may
        // mention the shared controller while explaining why it is not used.
        let usesShared = source
            .split(separator: "\n")
            .contains { line in
                let code = line.drop { $0 == " " || $0 == "\t" }
                return !code.hasPrefix("//")
                    && code.contains("= GroupCallController.shared")
            }
        #expect(
            !usesShared,
            "the shared controller has an empty roster and cannot place or receive a group call"
        )
    }

    @Test func theAppGivesTheControllerItsRealRoster() throws {
        let source = try Self.appSource("CuztomSignalApp.swift")
        #expect(
            source.contains("GroupCallController(roster: roster)"),
            "the controller must be built with the same roster the view model primes"
        )
    }

    @Test func theEagerIdMapLoadIsGone() throws {
        // The map lives behind the sync loop's live manager, which is not running
        // when the app configures. Loading it there failed every launch and left
        // inbound calls unresolvable for the rest of the process.
        let source = try Self.appSource("CuztomSignalApp.swift")
        let rosterSource = try Self.appSource("NativeGroupRoster.swift")
        #expect(
            !source.contains("loadGroupIdMap()"),
            "the id map must be loaded on first use, not at configure time"
        )
        #expect(
            rosterSource.contains("func masterKeyHex(forGroupIdHex groupIdHex: String) async"),
            "the roster must resolve ids lazily"
        )
    }

    @Test func anEmptyRosterIsReportedRatherThanSilentlyAccepted() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/CuztomSignalCore/GroupCallController.swift"),
            encoding: .utf8
        )
        #expect(
            source.contains("roster for this group is empty"),
            "an unreadable roster must be reported; the call connects with nobody identifiable"
        )
    }
}

/// The C ABI is a contract across three places: the C header, the Rust
/// `CORE_ABI_VERSION`, and the Swift loader that refuses a mismatched dylib.
/// Drift between them does not fail to build; it fails at `dlopen` on a user's
/// machine with a log line about an ABI number.
///
/// These read the checked-in files rather than the constants, so bumping one and
/// forgetting the others is caught here.
@Suite("Native ABI contract")
struct NativeABIContractTests {
    private static func repositoryRoot() -> URL {
        // #filePath is Tests/CuztomSignalCoreTests/<this file>.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func contents(of relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    /// The first capture group of the first match, or nil.
    private static func firstCapture(
        _ text: String,
        pattern: String
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    /// Every capture group of the first group across all matches.
    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
    }

    @Test func theHeaderDeclaresTheVersionSwiftExpects() throws {
        let header = try Self.contents(of: "rust-core/include/cuztom_signal_core.h")
        let version = try #require(
            Self.firstCapture(
                header,
                pattern: #"#define\s+CUZTOM_SIGNAL_CORE_ABI_VERSION\s+([0-9]+)u"#
            ),
            "the header does not define CUZTOM_SIGNAL_CORE_ABI_VERSION"
        )
        #expect(
            UInt32(version) == RustCoreService.expectedNativeABI,
            "header says \(version), the loader expects \(RustCoreService.expectedNativeABI)"
        )
    }

    @Test func theRustConstantMatchesTheHeader() throws {
        let source = try Self.contents(of: "rust-core/src/lib.rs")
        let version = try #require(
            Self.firstCapture(
                source,
                pattern: #"pub\s+const\s+CORE_ABI_VERSION:\s*u32\s*=\s*([0-9]+)"#
            ),
            "the Rust source does not declare CORE_ABI_VERSION"
        )
        #expect(
            UInt32(version) == RustCoreService.expectedNativeABI,
            "Rust says \(version), the loader expects \(RustCoreService.expectedNativeABI)"
        )
    }

    @Test func theBundleVerifierReadsTheHeaderRatherThanAStaleLiteral() throws {
        // The verifier used to hardcode the expected ABI, so it went on checking
        // an old number after the ABI moved and reported a mismatch that looked
        // like a packaging fault rather than a stale check.
        let script = try Self.contents(of: "scripts/verify-app.sh")
        #expect(
            !script.contains("expected_abi=2"),
            "the verifier must not carry a hardcoded ABI"
        )
        #expect(
            script.contains("CUZTOM_SIGNAL_CORE_ABI_VERSION"),
            "the verifier should read the expected ABI from the header"
        )
    }

    @Test func everySymbolTheLoaderLooksUpIsDeclaredInTheHeader() throws {
        // A `dlsym` for a name the dylib does not export returns null, which is
        // then bit-cast to a function pointer. Calling it is a crash, not an
        // error, so the loader may only look up declared symbols.
        let header = try Self.contents(of: "rust-core/include/cuztom_signal_core.h")
        let loader = try Self.contents(of: "Sources/CuztomSignalCore/RustCoreService.swift")
        let declared = Set(Self.declaredSymbols(in: header))
        let looked = Set(Self.lookedUpSymbols(in: loader))
        #expect(!looked.isEmpty, "the loader looks up symbols")
        for symbol in looked.sorted() {
            #expect(
                declared.contains(symbol),
                "\(symbol) is looked up but not declared in the header"
            )
        }
    }

    @Test func theSetOfUnwiredHeaderCommandsHasNotGrown() throws {
        // Some header commands are declared but not wired, either because they
        // are superseded or because the native side still refuses them. That is
        // allowed; silently *adding* to the list is not, because it means a new
        // capability was declared and then quietly left unreachable.
        let header = try Self.contents(of: "rust-core/include/cuztom_signal_core.h")
        let loader = try Self.contents(of: "Sources/CuztomSignalCore/RustCoreService.swift")
        let unwired = Set(Self.declaredSymbols(in: header))
            .subtracting(Self.lookedUpSymbols(in: loader))
            .subtracting(["core_cmd_string_free"])
        #expect(
            unwired == Self.knownUnwired,
            "unwired header commands changed: \\(unwired.sorted())"
        )
    }

    /// Header commands that exist but are not reachable from Swift.
    ///
    /// `core_cmd_init` is superseded by `core_cmd_init_encrypted`, which is what
    /// the loader resolves. The group management commands all return "not
    /// implemented" natively, so a binding would only expose a control that
    /// always fails. `core_cmd_group_roster` and `core_cmd_group_id_map` are
    /// deliberately absent: group calls need those two and they are wired.
    private static let knownUnwired: Set<String> = [
        "core_cmd_init",
        "core_cmd_group_get_info",
        "core_cmd_group_update_title",
        "core_cmd_group_update_avatar",
        "core_cmd_group_add_members",
        "core_cmd_group_remove_members",
        "core_cmd_group_promote_member",
        "core_cmd_group_demote_member",
        "core_cmd_group_get_invite_link",
        "core_cmd_group_revoke_invite_link",
        "core_cmd_group_leave",
    ]

    /// Every symbol the header declares.
    ///
    /// Matched across the whole file rather than line by line, because a
    /// declaration with parameters on their own lines does not end in `);` on
    /// the line the name appears on.
    private static func declaredSymbols(in header: String) -> [String] {
        matches(
            of: #"\b((?:core_cmd|core_free_string|core_last_error|core_abi_version)[A-Za-z0-9_]*)\s*\("#,
            in: header
        )
    }

    /// Every symbol name the loader passes to `dlsym`.
    private static func lookedUpSymbols(in loader: String) -> [String] {
        matches(of: #"dlsym\([^,]+,\s*"([^"]+)""#, in: loader)
    }
}
