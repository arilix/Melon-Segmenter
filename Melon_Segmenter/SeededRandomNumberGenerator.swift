import Foundation

/// A small, deterministic PRNG (SplitMix64) conforming to
/// `RandomNumberGenerator`. Swift's `SystemRandomNumberGenerator` (the
/// default behind `.random(in:)`/`.shuffled()`) is not seedable, so
/// anything that needs reproducible output across runs — sampling, node
/// initialization — must thread one of these through explicitly via the
/// `using:` overloads.
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // Avoid the degenerate all-zero state.
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
