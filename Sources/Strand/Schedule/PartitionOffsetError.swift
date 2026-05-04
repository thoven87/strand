enum PartitionOffsetError: Error {
    case invalidOffset(String)
    case invalidPartition(String)
    case invalidDuration(String)
    case offsetOutOfRange(Int64, Int64)
}
