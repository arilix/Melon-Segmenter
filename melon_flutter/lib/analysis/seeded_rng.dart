/// Deterministic SplitMix64 PRNG so the same photo always gives the same metrics.
class SeededRng {
  int _state;
  SeededRng(int seed) : _state = seed == 0 ? -0x61C8864680B583EB : seed;

  int nextInt64() {
    _state = _state + -0x61C8864680B583EB;
    var z = _state;
    z = (z ^ (z >>> 30)) * -0x40A7B892E31B1A47;
    z = (z ^ (z >>> 27)) * -0x6B2FB644ECCEEE15;
    return z ^ (z >>> 31);
  }

  /// Uniform integer in [0, n).
  int nextBelow(int n) => (nextInt64() >>> 1) % n;

  /// Uniform double in [0, 1).
  double nextDouble() => (nextInt64() >>> 11) / 9007199254740992.0;

  /// Fisher-Yates shuffle, in place.
  void shuffle<T>(List<T> list) {
    for (var i = list.length - 1; i > 0; i--) {
      final j = nextBelow(i + 1);
      final t = list[i];
      list[i] = list[j];
      list[j] = t;
    }
  }
}
