import CoreGraphics
import Foundation

/// Tuning parameters for the DBL-GNG engine below.
struct GNGConfig {
    var maxNodes: Int = 2000
    /// L1 in the reference implementation: winner-node learning rate.
    var alpha: Double = 0.5
    /// L2 in the reference implementation: neighbor-node learning rate.
    var beta: Double = 0.01
    /// Per-epoch global error decay applied to every node.
    var errorDecayFactor: Double = 0.5
    /// Error-halving factor applied to a node right after it's split.
    var newNodeErrorFactor: Double = 0.5
    /// Number of (seed, neighbor) node pairs used to initialize the graph.
    var numberOfStartingPoints: Int = 10
    var maxEpochs: Int = 60
    var plateauWindow: Int = 5
    var plateauRelativeImprovement: Double = 0.01
    /// Nodes with error above this percentile are candidates for splitting each epoch.
    var insertionQuantile: Double = 0.85
    /// Hard cap on how many nodes can be inserted in a single epoch — without
    /// this, insertions scale with current node count and compound
    /// exponentially (20 nodes → thousands within ~30 epochs), making later
    /// epochs far more expensive than early ones.
    var maxInsertionsPerEpoch: Int = 20
    /// Chance, per epoch, of pruning nodes that never won as the nearest node.
    var pruneChance: Double = 0.1
    /// Absolute early-stop threshold, in the same linear pixel units as the
    /// input points: once the mean distance from sampled points to their
    /// nearest node drops to/below this, stop growing — checked in addition
    /// to (not instead of) the relative plateau check above.
    var stopError: Double = 1.5
}

/// Swift port of **DBL-GNG** (Distributed Batch Learning Growing Neural Gas,
/// https://github.com/CornerSiow/DBL-GNG). Unlike vanilla GNG (Fritzke 1995),
/// it processes the whole point cloud in batched "epochs" — one pass over
/// all points per epoch instead of one random sample at a time — recomputes
/// edges each epoch purely from which node pairs actually won together, and
/// can insert many new nodes per epoch (every node above the 85th error
/// percentile), which converges in far fewer passes over the data.
///
/// On top of the reference algorithm, this adds early stopping: epochs stop
/// once the mean quantization error (mean *linear* distance from each
/// sampled point to its nearest node — `KDTree.nearestTwo` returns squared
/// distance, so this is explicitly `sqrt`'d before use) plateaus, or drops
/// to/below `GNGConfig.stopError`, instead of always running to `maxEpochs`.
///
/// All randomness (`shuffled`, `random(in:)`) is routed through an explicit
/// `RandomNumberGenerator` passed into `train(points:rng:)`, so results are
/// reproducible across runs given the same seed — the system RNG used by
/// the free `.random`/`.shuffled` functions is not seedable.
final class GrowingNeuralGas {
    private(set) var positions: [CGPoint] = []
    private var errors: [Double] = []
    private var edges: Set<Edge> = []
    private var meanErrorHistory: [Double] = []
    private(set) var stoppedGrowing = false

    private struct Edge: Hashable, Comparable {
        let a: Int
        let b: Int
        init(_ x: Int, _ y: Int) {
            a = min(x, y)
            b = max(x, y)
        }
        static func < (lhs: Edge, rhs: Edge) -> Bool {
            (lhs.a, lhs.b) < (rhs.a, rhs.b)
        }
    }

    let config: GNGConfig
    private let eps = 1e-4

    init(config: GNGConfig = GNGConfig()) {
        self.config = config
    }

    var nodeCount: Int { positions.count }
    var edgeCount: Int { edges.count }
    var edgeList: [(Int, Int)] { edges.map { ($0.a, $0.b) } }

    func train<RNG: RandomNumberGenerator>(points: [CGPoint], rng: inout RNG) {
        guard points.count >= 4 else { return }
        initializeDistributedNodes(
            points: points,
            pairCount: max(1, min(config.numberOfStartingPoints, points.count / 4)),
            rng: &rng
        )

        for _ in 0..<config.maxEpochs {
            guard !positions.isEmpty else { break }

            var deltaW1x = [Double](repeating: 0, count: positions.count)
            var deltaW1y = [Double](repeating: 0, count: positions.count)
            var deltaW2x = [Double](repeating: 0, count: positions.count)
            var deltaW2y = [Double](repeating: 0, count: positions.count)
            var a1 = [Double](repeating: 0, count: positions.count)
            var a2 = [Double](repeating: 0, count: positions.count)
            var coOccurrence = [[Int: Double]](repeating: [:], count: positions.count)

            // Order doesn't matter here: every use below (position deltas,
            // activation counts) is a commutative accumulation into
            // per-index arrays, so Set's per-process iteration order can't
            // change the numeric result.
            var neighborLists = [[Int]](repeating: [], count: positions.count)
            for edge in edges {
                neighborLists[edge.a].append(edge.b)
                neighborLists[edge.b].append(edge.a)
            }

            // Rebuilt every epoch since node positions move each epoch;
            // turns the dominant cost (nearest-two search × every sampled
            // point) from O(nodes) into O(log nodes) per point.
            let tree = KDTree(points: positions)
            var totalError: Double = 0

            for p in points {
                let (s1, s2, squaredDist) = tree.nearestTwo(to: p)
                guard s1 >= 0 else { continue }

                // KDTree.nearestTwo returns squared distance; everything
                // below that's compared against a linear-pixel threshold
                // (stopError) or matches the reference algorithm's own use
                // of linear distance for error accumulation needs the sqrt.
                let d1 = squaredDist.squareRoot()

                totalError += d1
                errors[s1] += d1 * config.alpha

                deltaW1x[s1] += (p.x - positions[s1].x) * config.alpha
                deltaW1y[s1] += (p.y - positions[s1].y) * config.alpha
                a1[s1] += 1

                for neighbor in neighborLists[s1] {
                    deltaW2x[neighbor] += (p.x - positions[neighbor].x) * config.beta
                    deltaW2y[neighbor] += (p.y - positions[neighbor].y) * config.beta
                    a2[neighbor] += 1
                }

                if s2 >= 0 {
                    coOccurrence[s1][s2, default: 0] += 1
                    coOccurrence[s2][s1, default: 0] += 1
                }
            }

            for i in positions.indices {
                positions[i].x += deltaW1x[i] / (a1[i] + eps) + deltaW2x[i] / (a2[i] + eps)
                positions[i].y += deltaW1y[i] / (a1[i] + eps) + deltaW2y[i] / (a2[i] + eps)
            }

            edges = []
            for i in coOccurrence.indices {
                // Dictionary iteration order is also per-process random, but
                // this only feeds `edges.insert` (Set membership), which is
                // order-independent, so no sorting needed here.
                for (j, count) in coOccurrence[i] where count > 0 && j > i {
                    edges.insert(Edge(i, j))
                }
            }

            let isolationRemap = removeIsolatedNodes()

            for i in errors.indices { errors[i] *= config.errorDecayFactor }

            if Double.random(in: 0..<1, using: &rng) < config.pruneChance {
                // `a1` is indexed by this epoch's *pre-isolation-removal*
                // node numbering, but `positions`/`errors`/`edges` were just
                // re-indexed by `removeIsolatedNodes`. Remap `a1` through
                // the same mapping before using it, or this reads activation
                // counts for the wrong nodes entirely.
                var remappedActivation = [Double](repeating: 0, count: positions.count)
                for (oldIndex, newIndex) in isolationRemap.enumerated() where newIndex >= 0 {
                    remappedActivation[newIndex] = a1[oldIndex]
                }
                removeNodes(where: { remappedActivation[$0] == 0 })
            }

            addNewNodes()

            let meanError = points.isEmpty ? 0 : totalError / Double(points.count)
            if meanError <= config.stopError {
                stoppedGrowing = true
                break
            }
            if trackPlateau(meanError) { break }
        }
    }

    /// Seeds the graph with `pairCount` (node, neighbor) pairs spread across
    /// the data: each iteration picks a random seed from the remaining pool,
    /// pairs it with its 3rd-nearest point, then removes that local
    /// neighborhood from the pool before picking the next seed.
    private func initializeDistributedNodes<RNG: RandomNumberGenerator>(
        points: [CGPoint], pairCount: Int, rng: inout RNG
    ) {
        var pool = points.shuffled(using: &rng)
        positions = []
        errors = []
        edges = []

        let batchSize = max(1, pool.count / pairCount)

        for _ in 0..<pairCount {
            guard pool.count > batchSize + 2 else { break }

            let tailStart = max(0, pool.count - batchSize)
            let seedIndex = Int.random(in: tailStart..<pool.count, using: &rng)
            let seed = pool[seedIndex]

            let sortedIndices = pool.indices.sorted {
                distanceSquared(pool[$0], seed) < distanceSquared(pool[$1], seed)
            }
            guard sortedIndices.count > 2 else { break }
            let neighbor = pool[sortedIndices[2]]

            let indexA = positions.count
            let indexB = positions.count + 1
            positions.append(seed)
            positions.append(neighbor)
            errors.append(0)
            errors.append(0)
            edges.insert(Edge(indexA, indexB))

            let keep = Set(sortedIndices.dropFirst(batchSize))
            pool = keep.sorted().map { pool[$0] }
        }

        if positions.count < 2, points.count >= 2 {
            positions = [points[0], points[1]]
            errors = [0, 0]
            edges = [Edge(0, 1)]
        }
    }

    private func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    /// Returns the old-index → new-index remap (-1 for removed nodes) so
    /// callers can keep any epoch-local per-node arrays (like `a1`/`a2`) in
    /// sync, the same way the reference implementation re-indexes its own
    /// activation arrays whenever it deletes nodes.
    @discardableResult
    private func removeIsolatedNodes() -> [Int] {
        var degree = [Int](repeating: 0, count: positions.count)
        for edge in edges {
            degree[edge.a] += 1
            degree[edge.b] += 1
        }
        return removeNodes(where: { degree[$0] == 0 })
    }

    /// Removes every node matching `predicate` in one pass. Rebuilds
    /// positions/errors/edges exactly once regardless of how many nodes are
    /// removed — removing them one at a time would rebuild the whole edge
    /// set per removal, which gets quadratic when many nodes are isolated
    /// in the same epoch. Returns the old-index → new-index remap (-1 for
    /// removed nodes); an identity mapping if nothing was removed.
    @discardableResult
    private func removeNodes(where predicate: (Int) -> Bool) -> [Int] {
        let toRemove = Set(positions.indices.filter(predicate))
        guard !toRemove.isEmpty else { return Array(positions.indices) }

        var remap = [Int](repeating: -1, count: positions.count)
        var newPositions: [CGPoint] = []
        var newErrors: [Double] = []
        newPositions.reserveCapacity(positions.count - toRemove.count)
        newErrors.reserveCapacity(errors.count - toRemove.count)

        for i in positions.indices where !toRemove.contains(i) {
            remap[i] = newPositions.count
            newPositions.append(positions[i])
            newErrors.append(errors[i])
        }

        positions = newPositions
        errors = newErrors
        edges = Set(edges.compactMap { edge -> Edge? in
            guard !toRemove.contains(edge.a), !toRemove.contains(edge.b) else { return nil }
            return Edge(remap[edge.a], remap[edge.b])
        })
        return remap
    }

    /// Splits every node whose error is above `insertionQuantile`, inserting
    /// a new node between it and its highest-error neighbor each time.
    private func addNewNodes() {
        guard !errors.isEmpty else { return }
        let sortedErrors = errors.sorted()
        let quantileIndex = min(sortedErrors.count - 1, Int(Double(sortedErrors.count) * config.insertionQuantile))
        let threshold = sortedErrors[quantileIndex]
        let insertionBudget = min(config.maxInsertionsPerEpoch, errors.filter { $0 > threshold }.count)

        // Sorted so tie-breaks in the `max(by:)` calls below are
        // deterministic regardless of Set's per-process iteration order —
        // this is the one place that order could change which node is
        // picked when two neighbors have exactly equal error (most likely
        // right after a split, where both halves get the same halved value).
        var neighborLists = [[Int]](repeating: [], count: positions.count)
        for edge in edges.sorted() {
            neighborLists[edge.a].append(edge.b)
            neighborLists[edge.b].append(edge.a)
        }

        for _ in 0..<insertionBudget {
            guard positions.count < config.maxNodes else { return }
            guard let q1 = errors.indices.max(by: { errors[$0] < errors[$1] }), errors[q1] > 0 else { return }

            let neighbors = neighborLists[q1]
            guard !neighbors.isEmpty else { return }
            guard let q2 = neighbors.max(by: { errors[$0] < errors[$1] }), errors[q2] > 0 else { return }

            let newPosition = CGPoint(x: (positions[q1].x + positions[q2].x) / 2, y: (positions[q1].y + positions[q2].y) / 2)
            let q3 = positions.count
            positions.append(newPosition)

            errors[q1] *= config.newNodeErrorFactor
            errors[q2] *= config.newNodeErrorFactor
            errors.append((errors[q1] + errors[q2]) / 2)

            edges.remove(Edge(q1, q2))
            edges.insert(Edge(q1, q3))
            edges.insert(Edge(q2, q3))

            neighborLists.append([])
            neighborLists[q1].removeAll { $0 == q2 }
            neighborLists[q2].removeAll { $0 == q1 }
            neighborLists[q1].append(q3)
            neighborLists[q3].append(q1)
            neighborLists[q2].append(q3)
            neighborLists[q3].append(q2)
        }
    }

    private func trackPlateau(_ meanError: Double) -> Bool {
        meanErrorHistory.append(meanError)
        guard meanErrorHistory.count >= config.plateauWindow + 1 else { return false }

        let recent = meanErrorHistory.suffix(config.plateauWindow + 1)
        let first = recent.first!
        let last = recent.last!
        guard first > 0 else {
            stoppedGrowing = true
            return true
        }
        if (first - last) / first < config.plateauRelativeImprovement {
            stoppedGrowing = true
            return true
        }
        return false
    }
}
