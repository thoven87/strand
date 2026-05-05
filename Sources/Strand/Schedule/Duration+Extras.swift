#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

extension Duration {

    public static func minutes(_ minutes: Int) -> Duration {
        .seconds(minutes * 60)
    }

    public static func hours(_ hours: Int) -> Duration {
        .seconds(hours * 3600)
    }

    /// Create a Duration from days
    public static func days(_ days: Int) -> Duration {
        .seconds(days * 86400)
    }

    /// Convert Duration to TimeInterval (seconds as Double)
    public var timeInterval: TimeInterval {
        let (seconds, attoseconds) = self.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    /// Human-readable description of the duration.
    ///
    /// Uses compound notation when the value doesn't divide evenly into the
    /// largest unit, e.g. 90 minutes → "1h 30m" rather than "1 hour" (which
    /// would silently discard the remaining 30 minutes via integer truncation).
    public var humanReadable: String {
        let totalSeconds = Int(self.components.seconds)

        if totalSeconds < 60 {
            return "\(totalSeconds) second\(totalSeconds == 1 ? "" : "s")"
        } else if totalSeconds < 3600 {
            let minutes = totalSeconds / 60
            let secs = totalSeconds % 60
            if secs == 0 {
                return "\(minutes) minute\(minutes == 1 ? "" : "s")"
            }
            return "\(minutes)m \(secs)s"
        } else if totalSeconds < 86400 {
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            if minutes == 0 {
                return "\(hours) hour\(hours == 1 ? "" : "s")"
            }
            return "\(hours)h \(minutes)m"
        } else {
            let days = totalSeconds / 86400
            let hours = (totalSeconds % 86400) / 3600
            if hours == 0 {
                return "\(days) day\(days == 1 ? "" : "s")"
            }
            return "\(days)d \(hours)h"
        }
    }
}
