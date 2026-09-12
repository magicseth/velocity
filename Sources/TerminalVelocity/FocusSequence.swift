import Foundation

/// Companion failures must never prevent reaching the destination the user chose.
@MainActor enum FocusSequence {
    struct Result {
        let selectedFocused: Bool
        let companionsFocused: Bool
    }

    static func run(companions: [WindowEntry], selected: WindowEntry,
                    focus: (WindowEntry) async -> Bool) async -> Result {
        var companionsFocused = true
        for entry in companions {
            if !(await focus(entry)) { companionsFocused = false }
        }
        let selectedFocused = await focus(selected)
        return Result(selectedFocused: selectedFocused, companionsFocused: companionsFocused)
    }
}
