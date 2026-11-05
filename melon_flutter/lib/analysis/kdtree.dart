/// Minimal 2D k-d tree for nearest / second-nearest queries.
class KDTree {
  final List<double> _xs;
  final List<double> _ys;
  late final List<int> _order; // implicit tree: median at mid of each range
  KDTree(this._xs, this._ys) {
    _order = List<int>.generate(_xs.length, (i) => i);
    _build(0, _order.length, 0);
  }

  void _build(int lo, int hi, int depth) {
    if (hi - lo <= 1) return;
    final axis = depth % 2;
    final sub = _order.sublist(lo, hi);
    final v = axis == 0 ? _xs : _ys;
    sub.sort((a, b) => v[a].compareTo(v[b]));
    _order.setRange(lo, hi, sub);
    final mid = lo + (hi - lo) ~/ 2;
    _build(lo, mid, depth + 1);
    _build(mid + 1, hi, depth + 1);
  }

  int bestIndex = -1, secondIndex = -1;
  double bestDist = double.infinity, secondDist = double.infinity;

  /// After the call: [bestIndex], [secondIndex], [bestDist] (squared).
  void nearestTwo(double px, double py) {
    bestIndex = -1;
    secondIndex = -1;
    bestDist = double.infinity;
    secondDist = double.infinity;
    _visit(0, _order.length, 0, px, py);
  }

  void _visit(int lo, int hi, int depth, double px, double py) {
    if (hi <= lo) return;
    final mid = lo + (hi - lo) ~/ 2;
    final idx = _order[mid];
    final dx = _xs[idx] - px, dy = _ys[idx] - py;
    final d = dx * dx + dy * dy;
    if (d < bestDist) {
      secondDist = bestDist;
      secondIndex = bestIndex;
      bestDist = d;
      bestIndex = idx;
    } else if (d < secondDist) {
      secondDist = d;
      secondIndex = idx;
    }
    final axis = depth % 2;
    final delta = axis == 0 ? px - _xs[idx] : py - _ys[idx];
    if (delta < 0) {
      _visit(lo, mid, depth + 1, px, py);
      if (delta * delta < secondDist) _visit(mid + 1, hi, depth + 1, px, py);
    } else {
      _visit(mid + 1, hi, depth + 1, px, py);
      if (delta * delta < secondDist) _visit(lo, mid, depth + 1, px, py);
    }
  }
}
