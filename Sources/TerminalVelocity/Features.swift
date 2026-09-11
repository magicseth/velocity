/// Opt in at build time. Public downloads never enable experimental agent features.
enum Features {
    #if VELOCITY_EXPERIMENTAL
    static let experimentalAgents = true
    #else
    static let experimentalAgents = false
    #endif
}
