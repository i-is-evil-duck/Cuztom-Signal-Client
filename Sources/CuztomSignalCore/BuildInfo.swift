import Foundation

/// Human-readable build metadata for diagnostics and the settings/header UI.
/// Release bundles should provide `CFBundleShortVersionString` and
/// `CFBundleVersion`; local SwiftPM runs intentionally fall back to `dev`.
public enum BuildInfo {
    public static var displayTag: String {
        displayTag(environment: ProcessInfo.processInfo.environment)
    }

    public static func displayTag(
        shortVersion: String? = nil,
        buildNumber: String? = nil
    ) -> String {
        displayTag(
            environment: [:],
            shortVersion: shortVersion,
            buildNumber: buildNumber
        )
    }

    public static func displayTag(
        environment: [String: String],
        shortVersion: String? = nil,
        buildNumber: String? = nil
    ) -> String {
        if let override = environment["CUZTOM_SIGNAL_BUILD_TAG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return "Build \(override)"
        }

        let bundle = Bundle.main
        let version = nonEmpty(
            shortVersion
                ?? environment["CUZTOM_SIGNAL_BUILD_VERSION"]
                ?? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ) ?? "dev"
        let build = nonEmpty(
            buildNumber
                ?? environment["CUZTOM_SIGNAL_BUILD_NUMBER"]
                ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )

        if let build, build != version {
            return "Build \(version) (\(build))"
        }
        return "Build \(version)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
