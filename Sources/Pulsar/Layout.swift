import CoreGraphics

/// Pure geometry. Kept free of AX and AppKit so it can be reasoned about (and unit-tested)
/// without a window server.
///
/// The central problem this file solves: **apps clamp their own size**. AX provides no way to ask
/// for a window's minimum, so a layout that divides the screen evenly can hand a window a pane
/// smaller than it accepts; the app then keeps its larger size and overlaps its neighbour.
/// Everything here is written so that (a) known minimums are respected, and (b) when the minimums
/// cannot all fit, panes run off the trailing edge instead of piling on top of one another.
enum Layout {

    /// Divide `total` among weighted slots, respecting per-slot minimums (water-filling).
    ///
    /// Slots that cannot get their minimum at the proportional share are pinned to it, and the
    /// remaining space is redistributed among the rest. If the minimums alone exceed `total`, the
    /// sum of the result exceeds `total` deliberately: panes then run past the screen edge rather
    /// than overlap, because the caller places each pane after the previous one.
    static func slice(weights: [CGFloat], minimums: [CGFloat], total: CGFloat) -> [CGFloat] {
        let n = weights.count
        guard n > 0 else { return [] }
        let safeWeights = weights.map { max($0, 0.05) }
        let safeMins = minimums.count == n ? minimums.map { max($0, 1) } : Array(repeating: 1, count: n)

        var result = [CGFloat](repeating: 0, count: n)
        var pending = Array(0..<n)
        var space = total
        var weightLeft = safeWeights.reduce(0, +)

        // Pin every slot whose proportional share falls below its minimum, then retry.
        var pinned = true
        while pinned && !pending.isEmpty {
            pinned = false
            for i in pending where weightLeft > 0 {
                let share = space * safeWeights[i] / weightLeft
                if share < safeMins[i] {
                    result[i] = safeMins[i]
                    space -= safeMins[i]
                    weightLeft -= safeWeights[i]
                    pending.removeAll { $0 == i }
                    pinned = true
                    break
                }
            }
        }

        if !pending.isEmpty, weightLeft > 0 {
            let scale = space / weightLeft
            for i in pending { result[i] = max(safeWeights[i] * scale, 1) }
        } else {
            for i in pending { result[i] = safeMins[i] }
        }
        return result
    }

    /// Slice `rect` into one frame per window along `orientation`, honouring minimum sizes.
    ///
    /// Positions accumulate from the leading edge, so panes never share pixels. The last pane takes
    /// the remainder when everything fits, so rounding leaves no seam at the trailing edge.
    static func frames(weights: [CGFloat],
                       minimums: [CGFloat],
                       in rect: CGRect,
                       orientation: Orientation) -> [CGRect] {
        guard !weights.isEmpty else { return [] }
        var lengths = slice(weights: weights, minimums: minimums,
                            total: orientation == .horizontal ? rect.width : rect.height)
        let available = orientation == .horizontal ? rect.width : rect.height
        let used = lengths.reduce(0, +)
        if used <= available, !lengths.isEmpty {
            lengths[lengths.count - 1] += available - used     // absorb rounding
        }

        var out: [CGRect] = []
        out.reserveCapacity(lengths.count)
        var offset: CGFloat = 0
        for length in lengths {
            if orientation == .horizontal {
                out.append(CGRect(x: rect.minX + offset, y: rect.minY, width: length, height: rect.height))
            } else {
                out.append(CGRect(x: rect.minX, y: rect.minY + offset, width: rect.width, height: length))
            }
            offset += length
        }
        return out
    }

    /// Grid for 3+ windows: rows of columns, each axis allocated with `slice`.
    ///
    /// A single row thin enough for 7 windows puts every pane below the minimum width apps accept,
    /// so a grid keeps panes usable while still partitioning the screen.
    static func grid(weights: [CGFloat],
                     minWidths: [CGFloat],
                     minHeights: [CGFloat],
                     in rect: CGRect,
                     columns: Int? = nil) -> [CGRect] {
        let n = weights.count
        guard n > 0 else { return [] }
        if n == 1 { return [rect] }

        let cols = max(1, min(n, columns ?? preferredColumns(for: n)))
        let rows = Int(ceil(Double(n) / Double(cols)))

        // Row heights first, each row sized by the tallest minimum among its windows.
        var rowMinHeights = [CGFloat](repeating: 1, count: rows)
        for row in 0..<rows {
            let start = row * cols
            let end = min(n, start + cols)
            guard start < end else { continue }
            rowMinHeights[row] = (start..<end)
                .map { minHeights.indices.contains($0) ? minHeights[$0] : 1 }
                .max() ?? 1
        }
        var rowLengths = slice(weights: Array(repeating: 1, count: rows),
                               minimums: rowMinHeights,
                               total: rect.height)
        let rowUsed = rowLengths.reduce(0, +)
        if rowUsed <= rect.height, !rowLengths.isEmpty {
            rowLengths[rowLengths.count - 1] += rect.height - rowUsed
        }

        var out: [CGRect] = []
        out.reserveCapacity(n)
        var y = rect.minY
        for row in 0..<rows {
            let start = row * cols
            let end = min(n, start + cols)
            guard start < end else { continue }
            let count = end - start

            var colWidths = slice(weights: Array(weights[start..<end]),
                                  minimums: Array(minWidths[start..<end]),
                                  total: rect.width)
            let colUsed = colWidths.reduce(0, +)
            if colUsed <= rect.width, !colWidths.isEmpty {
                colWidths[colWidths.count - 1] += rect.width - colUsed
            }

            var x = rect.minX
            for i in 0..<count {
                out.append(CGRect(x: x, y: y, width: colWidths[i], height: rowLengths[row]))
                x += colWidths[i]
            }
            y += rowLengths[row]
        }
        return out
    }

    /// Square-ish column count, biased toward columns because screens are wider than tall.
    static func preferredColumns(for n: Int) -> Int {
        guard n > 1 else { return 1 }
        return max(1, Int((Double(n).squareRoot() * 1.15).rounded(.up)))
    }

    /// Neighbour index in a direction, for focus and move.
    static func neighbour(from index: Int, count: Int, direction: Direction,
                          orientation: Orientation) -> Int? {
        guard count > 0 else { return nil }
        let forward: Bool
        switch direction {
        case .left, .up:  forward = false
        case .right, .down: forward = true
        }
        let candidate = forward ? index + 1 : index - 1
        return (candidate >= 0 && candidate < count) ? candidate : nil
    }
}

enum Direction {
    case left, right, up, down
}
