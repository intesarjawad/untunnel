import Darwin

/// The scheduling class of every thread on the frame path.
///
/// A restorer's caller waits for the engine's workers inside each hop, so the caller and the
/// workers must be scheduled alike: a caller in a lower class is preempted while workers that
/// have nothing to do keep their cores, and workers in a lower class lose theirs to any busy
/// application while the caller waits for them.
public enum RealtimeThread {
    /// Declares the calling thread periodic at the model's hop: a quarter of each period of
    /// computation, due within half of it.
    /// - Returns: Whether the system accepted. A refusal leaves the thread at its quality of
    ///   service, which is slower under load and still correct.
    @discardableResult
    public static func requestTimeConstraint() -> Bool {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticksPerMillisecond = 1_000_000 * Double(timebase.denom) / Double(timebase.numer)
        let hop = Double(Tier.streamingHopMilliseconds) * ticksPerMillisecond
        var policy = thread_time_constraint_policy_data_t(
            period: UInt32(hop),
            computation: UInt32(hop / 4),
            constraint: UInt32(hop / 2),
            preemptible: 1
        )
        let count = mach_msg_type_number_t(
            MemoryLayout<thread_time_constraint_policy_data_t>.size
                / MemoryLayout<integer_t>.size)
        return withUnsafeMutablePointer(to: &policy) { policy in
            policy.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                thread_policy_set(
                    pthread_mach_thread_np(pthread_self()),
                    thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), words, count)
                    == KERN_SUCCESS
            }
        }
    }
}
