import Foundation
import os

/// Velocity's Julia doings, readable afterwards with
///   /usr/bin/log show --predicate 'subsystem == "velocity.julia"' --last 10m
/// Public strings on purpose: this is what Velocity DID (which tab, why not), never
/// what he said — a reply's text is not logged.
enum JuliaLog {
    private static let logger = Logger(subsystem: "velocity.julia", category: "hands")
    static func note(_ s: String) { logger.notice("\(s, privacy: .public)") }
}
