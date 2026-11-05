import 'dart:math' as math;

import 'kdtree.dart';
import 'seeded_rng.dart';

class GNGConfig {
  int maxNodes = 2000;
  double alpha = 0.5;
  double beta = 0.01;
  double errorDecayFactor = 0.5;
  double newNodeErrorFactor = 0.5;
  int numberOfStartingPoints = 10;
  int maxEpochs = 60;
  int plateauWindow = 5;
  double plateauRelativeImprovement = 0.01;
  double insertionQuantile = 0.85;
  int maxInsertionsPerEpoch = 20;
  double pruneChance = 0.1;
  double stopError = 1.5;
}

/// Dart port of DBL-GNG (Distributed Batch Learning Growing Neural Gas).
class GrowingNeuralGas {
  final GNGConfig config;
  GrowingNeuralGas([GNGConfig? c]) : config = c ?? GNGConfig();

  List<double> xs = [];
  List<double> ys = [];
  List<double> _errors = [];
  Set<int> _edges = {};
  final List<double> _history = [];
  bool stoppedGrowing = false;
  static const _eps = 1e-4;
  static const _shift = 20;
  static const _mask = (1 << _shift) - 1;

  static int _key(int x, int y) => x < y ? (x << _shift) | y : (y << _shift) | x;
  static int _ka(int k) => k >> _shift;
  static int _kb(int k) => k & _mask;

  int get nodeCount => xs.length;
  int get edgeCount => _edges.length;
  List<(int, int)> get edgeList => [for (final k in _edges) (_ka(k), _kb(k))];

  void train(List<double> px, List<double> py, SeededRng rng) {
    final n = px.length;
    if (n < 4) return;
    _initialize(px, py, math.max(1, math.min(config.numberOfStartingPoints, n ~/ 4)), rng);

    for (var epoch = 0; epoch < config.maxEpochs; epoch++) {
      final m = xs.length;
      if (m == 0) break;
      final dW1x = List<double>.filled(m, 0), dW1y = List<double>.filled(m, 0);
      final dW2x = List<double>.filled(m, 0), dW2y = List<double>.filled(m, 0);
      final a1 = List<double>.filled(m, 0), a2 = List<double>.filled(m, 0);
      final co = List<Map<int, int>>.generate(m, (_) => {});

      final neigh = List<List<int>>.generate(m, (_) => []);
      for (final k in _edges) {
        neigh[_ka(k)].add(_kb(k));
        neigh[_kb(k)].add(_ka(k));
      }

      final tree = KDTree(xs, ys);
      var totalError = 0.0;
      for (var i = 0; i < n; i++) {
        final x = px[i], y = py[i];
        tree.nearestTwo(x, y);
        final s1 = tree.bestIndex, s2 = tree.secondIndex;
        if (s1 < 0) continue;
        final d1 = math.sqrt(tree.bestDist);
        totalError += d1;
        _errors[s1] += d1 * config.alpha;
        dW1x[s1] += (x - xs[s1]) * config.alpha;
        dW1y[s1] += (y - ys[s1]) * config.alpha;
        a1[s1] += 1;
        for (final nb in neigh[s1]) {
          dW2x[nb] += (x - xs[nb]) * config.beta;
          dW2y[nb] += (y - ys[nb]) * config.beta;
          a2[nb] += 1;
        }
        if (s2 >= 0) {
          co[s1][s2] = (co[s1][s2] ?? 0) + 1;
          co[s2][s1] = (co[s2][s1] ?? 0) + 1;
        }
      }

      for (var i = 0; i < m; i++) {
        xs[i] += dW1x[i] / (a1[i] + _eps) + dW2x[i] / (a2[i] + _eps);
        ys[i] += dW1y[i] / (a1[i] + _eps) + dW2y[i] / (a2[i] + _eps);
      }

      _edges = {};
      for (var i = 0; i < m; i++) {
        co[i].forEach((j, c) {
          if (c > 0 && j > i) _edges.add(_key(i, j));
        });
      }

      final remap = _removeIsolated();
      for (var i = 0; i < _errors.length; i++) {
        _errors[i] *= config.errorDecayFactor;
      }

      if (rng.nextDouble() < config.pruneChance) {
        final act = List<double>.filled(xs.length, 0);
        for (var old = 0; old < remap.length; old++) {
          if (remap[old] >= 0) act[remap[old]] = a1[old];
        }
        _removeWhere((i) => act[i] == 0);
      }

      _addNewNodes();

      final meanError = totalError / n;
      if (meanError <= config.stopError) {
        stoppedGrowing = true;
        break;
      }
      if (_trackPlateau(meanError)) break;
    }
  }

  void _initialize(List<double> px, List<double> py, int pairCount, SeededRng rng) {
    final idx = List<int>.generate(px.length, (i) => i);
    rng.shuffle(idx);
    var poolX = [for (final i in idx) px[i]];
    var poolY = [for (final i in idx) py[i]];
    xs = [];
    ys = [];
    _errors = [];
    _edges = {};
    final batch = math.max(1, poolX.length ~/ pairCount);

    for (var p = 0; p < pairCount; p++) {
      if (poolX.length <= batch + 2) break;
      final tailStart = math.max(0, poolX.length - batch);
      final seedIdx = tailStart + rng.nextBelow(poolX.length - tailStart);
      final sx = poolX[seedIdx], sy = poolY[seedIdx];
      final order = List<int>.generate(poolX.length, (i) => i);
      final dist = List<double>.generate(poolX.length, (i) {
        final dx = poolX[i] - sx, dy = poolY[i] - sy;
        return dx * dx + dy * dy;
      });
      order.sort((a, b) => dist[a].compareTo(dist[b]));
      if (order.length <= 2) break;
      final nb = order[2];
      final a = xs.length;
      xs..add(sx)..add(poolX[nb]);
      ys..add(sy)..add(poolY[nb]);
      _errors..add(0)..add(0);
      _edges.add(_key(a, a + 1));
      final keep = order.sublist(batch)..sort();
      poolX = [for (final i in keep) poolX[i]];
      poolY = [for (final i in keep) poolY[i]];
    }
    if (xs.length < 2 && px.length >= 2) {
      xs = [px[0], px[1]];
      ys = [py[0], py[1]];
      _errors = [0, 0];
      _edges = {_key(0, 1)};
    }
  }

  List<int> _removeIsolated() {
    final degree = List<int>.filled(xs.length, 0);
    for (final k in _edges) {
      degree[_ka(k)]++;
      degree[_kb(k)]++;
    }
    return _removeWhere((i) => degree[i] == 0);
  }

  List<int> _removeWhere(bool Function(int) pred) {
    final remove = <int>{for (var i = 0; i < xs.length; i++) if (pred(i)) i};
    if (remove.isEmpty) return List<int>.generate(xs.length, (i) => i);
    final remap = List<int>.filled(xs.length, -1);
    final nx = <double>[], ny = <double>[], ne = <double>[];
    for (var i = 0; i < xs.length; i++) {
      if (remove.contains(i)) continue;
      remap[i] = nx.length;
      nx.add(xs[i]);
      ny.add(ys[i]);
      ne.add(_errors[i]);
    }
    xs = nx;
    ys = ny;
    _errors = ne;
    final newEdges = <int>{};
    for (final k in _edges) {
      final a = _ka(k), b = _kb(k);
      if (remove.contains(a) || remove.contains(b)) continue;
      newEdges.add(_key(remap[a], remap[b]));
    }
    _edges = newEdges;
    return remap;
  }

  void _addNewNodes() {
    if (_errors.isEmpty) return;
    final sorted = [..._errors]..sort();
    final qi = math.min(sorted.length - 1, (sorted.length * config.insertionQuantile).floor());
    final threshold = sorted[qi];
    final budget = math.min(config.maxInsertionsPerEpoch, _errors.where((e) => e > threshold).length);

    final neigh = List<List<int>>.generate(xs.length, (_) => []);
    final sortedEdges = _edges.toList()..sort();
    for (final k in sortedEdges) {
      neigh[_ka(k)].add(_kb(k));
      neigh[_kb(k)].add(_ka(k));
    }

    for (var step = 0; step < budget; step++) {
      if (xs.length >= config.maxNodes) return;
      var q1 = 0;
      for (var i = 1; i < _errors.length; i++) {
        if (_errors[i] > _errors[q1]) q1 = i;
      }
      if (_errors[q1] <= 0) return;
      final nbs = neigh[q1];
      if (nbs.isEmpty) return;
      var q2 = nbs.first;
      for (final c in nbs) {
        if (_errors[c] > _errors[q2]) q2 = c;
      }
      if (_errors[q2] <= 0) return;

      final q3 = xs.length;
      xs.add((xs[q1] + xs[q2]) / 2);
      ys.add((ys[q1] + ys[q2]) / 2);
      _errors[q1] *= config.newNodeErrorFactor;
      _errors[q2] *= config.newNodeErrorFactor;
      _errors.add((_errors[q1] + _errors[q2]) / 2);

      _edges.remove(_key(q1, q2));
      _edges.add(_key(q1, q3));
      _edges.add(_key(q2, q3));

      neigh.add([]);
      neigh[q1].remove(q2);
      neigh[q2].remove(q1);
      neigh[q1].add(q3);
      neigh[q3].add(q1);
      neigh[q2].add(q3);
      neigh[q3].add(q2);
    }
  }

  bool _trackPlateau(double meanError) {
    _history.add(meanError);
    if (_history.length < config.plateauWindow + 1) return false;
    final first = _history[_history.length - config.plateauWindow - 1];
    final last = _history.last;
    if (first <= 0) {
      stoppedGrowing = true;
      return true;
    }
    if ((first - last) / first < config.plateauRelativeImprovement) {
      stoppedGrowing = true;
      return true;
    }
    return false;
  }
}
