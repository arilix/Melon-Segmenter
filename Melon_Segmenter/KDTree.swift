import CoreGraphics

/// A minimal 2D k-d tree for nearest/second-nearest-neighbor queries.
/// Rebuilt once per epoch in `GrowingNeuralGas` (node positions move every
/// epoch, so the tree can't be reused across epochs) to replace the
/// O(nodeCount) linear scan with an O(log nodeCount) query per sampled
/// point — the same benefit `scipy.spatial.cKDTree` would give, without
/// leaving Swift or adding a server round-trip.
struct KDTree {
    private final class Node {
        let index: Int
        let point: CGPoint
        let axis: Int
        var left: Node?
        var right: Node?

        init(index: Int, point: CGPoint, axis: Int) {
            self.index = index
            self.point = point
            self.axis = axis
        }
    }

    private let root: Node?

    init(points: [CGPoint]) {
        var items = Array(points.enumerated())
        root = Self.build(&items, depth: 0)
    }

    private static func build(_ items: inout [(offset: Int, element: CGPoint)], depth: Int) -> Node? {
        guard !items.isEmpty else { return nil }

        let axis = depth % 2
        items.sort { axis == 0 ? $0.element.x < $1.element.x : $0.element.y < $1.element.y }
        let mid = items.count / 2
        let node = Node(index: items[mid].offset, point: items[mid].element, axis: axis)

        var left = Array(items[..<mid])
        var right = Array(items[(mid + 1)...])
        node.left = build(&left, depth: depth + 1)
        node.right = build(&right, depth: depth + 1)
        return node
    }

    /// Returns (nearestIndex, secondNearestIndex, nearestSquaredDistance).
    func nearestTwo(to point: CGPoint) -> (Int, Int, Double) {
        var best = (index: -1, dist: Double.infinity)
        var second = (index: -1, dist: Double.infinity)

        func visit(_ node: Node?) {
            guard let node else { return }

            let dx = node.point.x - point.x
            let dy = node.point.y - point.y
            let d = dx * dx + dy * dy

            if d < best.dist {
                second = best
                best = (node.index, d)
            } else if d < second.dist {
                second = (node.index, d)
            }

            let axisDelta = node.axis == 0 ? point.x - node.point.x : point.y - node.point.y
            let nearChild = axisDelta < 0 ? node.left : node.right
            let farChild = axisDelta < 0 ? node.right : node.left

            visit(nearChild)
            // Only descend into the far branch if it could still hold a
            // point closer than our current second-best — we need the
            // top *two* neighbors, so the prune bound uses `second.dist`
            // rather than the tighter single-NN bound of `best.dist`.
            if axisDelta * axisDelta < second.dist {
                visit(farChild)
            }
        }

        visit(root)
        return (best.index, second.index, best.dist)
    }
}
