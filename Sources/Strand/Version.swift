// MARK: - StrandVersion

/// Version information for the Strand SDK.
///
/// `StrandVersion.current` is the single source of truth for the SDK version.
/// It is embedded in worker heartbeats (``strand.workers.sdk_version``) so the
/// Loom dashboard can show which build of Strand is running each queue.
///
/// ## Updating on release
///
/// CI bumps this constant as part of the release workflow:
/// ```bash
/// sed -i 's/public static let current = ".*"/public static let current = "'$VERSION'"/' \
///     Sources/Strand/Version.swift
/// ```
///
/// No C bridge, no build plugin, no binary dependency required — Strand is pure
/// Swift and a plain constant is the right tool for a pure-Swift library.
public enum StrandVersion {
    /// The current Strand SDK version string.
    /// Updated by CI on each tagged release; `"dev"` on untagged builds.
    public static let current = "dev"
}
