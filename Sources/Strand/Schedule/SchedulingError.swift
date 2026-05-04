/// Errors that can occur during scheduling operations
public enum SchedulingError: Error, Sendable {
    case invalidSchedule(String)
    case invalidDuration(String)
    case invalidCronExpression(String)
    case timezoneError(String)
    case calculationError(String)
}
