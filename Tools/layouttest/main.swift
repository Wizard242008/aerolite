import Foundation
import CoreGraphics

// layouttest — dumps the geometry Layout produces for a battery of cases, as JSON, so the Python
// suite can assert invariants (no overlap, exact span, minimums respected) without a window server.

typealias Case = (String, [CGRect])

func framesH(_ weights: [CGFloat], _ mins: [CGFloat], _ w: CGFloat, _ h: CGFloat,
             _ ox: CGFloat = 0, _ oy: CGFloat = 0) -> [CGRect] {
    Layout.frames(weights: weights, minimums: mins,
                  in: CGRect(x: ox, y: oy, width: w, height: h), orientation: .horizontal)
}
func framesV(_ weights: [CGFloat], _ mins: [CGFloat], _ w: CGFloat, _ h: CGFloat) -> [CGRect] {
    Layout.frames(weights: weights, minimums: mins,
                  in: CGRect(x: 0, y: 0, width: w, height: h), orientation: .vertical)
}
func grid(_ n: Int, _ w: CGFloat, _ h: CGFloat, mins: [CGFloat] = [], columns: Int? = nil) -> [CGRect] {
    Layout.grid(weights: Array(repeating: 1, count: n),
                minWidths: mins.isEmpty ? Array(repeating: 1, count: n) : mins,
                minHeights: Array(repeating: 1, count: n),
                in: CGRect(x: 0, y: 0, width: w, height: h), columns: columns)
}

var cases: [Case] = []

// --- basic splits ---
cases.append(("eq2h", framesH([1, 1], [], 1000, 500)))
cases.append(("eq3h", framesH([1, 1, 1], [], 1000, 500)))
cases.append(("w21h", framesH([2, 1], [], 1000, 500)))
cases.append(("w13v", framesV([1, 3], [], 800, 600)))
cases.append(("eq4h", framesH([1, 1, 1, 1], [], 1000, 500)))
cases.append(("single", framesH([1], [], 1000, 500)))
cases.append(("none", framesH([], [], 1000, 500)))
cases.append(("offset", framesH([1, 1], [], 1000, 500, 120, 40)))
cases.append(("frac", framesH([1, 1, 1], [], 1000.5, 500)))

// --- degenerate weights ---
cases.append(("zeroW", framesH([0, 1], [], 1000, 500)))
cases.append(("negW", framesH([-5, 1], [], 1000, 500)))
cases.append(("hugeW", framesH([1000, 0.01], [], 1000, 500)))
cases.append(("tinyW", framesH([0.001, 0.001, 0.001], [], 1000, 500)))

// --- minimum sizes ---
cases.append(("minFits", framesH([1, 1], [660, 100], 1000, 500)))
cases.append(("minTight", framesH([1, 1], [400, 400], 1000, 500)))
cases.append(("minOverflow", framesH([1, 1], [700, 700], 1000, 500)))
cases.append(("minVertical", framesV([1, 1], [400, 620], 800, 1019)))
cases.append(("minMismatch", framesH([1, 1, 1], [300], 900, 500)))
cases.append(("minZero", framesH([1, 1], [0, 0], 1000, 500)))

// --- grids ---
for n in [2, 3, 4, 5, 6, 7, 8, 9, 10] {
    cases.append(("grid\(n)", grid(n, 1680, 1019)))
}
cases.append(("grid3min", grid(3, 1680, 1019, mins: [660, 400, 400])))
cases.append(("grid4min", grid(4, 1680, 1019, mins: [660, 660, 100, 100])))
cases.append(("gridForced2", grid(6, 1680, 1019, columns: 2)))
cases.append(("gridForced1", grid(5, 1680, 1019, columns: 1)))
cases.append(("gridTiny", grid(4, 320, 240)))

// --- neighbour logic ---
var neighbours: [String: [String: Int?]] = [:]
for dir in [Direction.left, .right, .up, .down] {
    let name = "\(dir)"
    var row: [String: Int?] = [:]
    for i in 0..<3 { row["\(i)"] = Layout.neighbour(from: i, count: 3, direction: dir, orientation: .horizontal) }
    neighbours[name] = row
}

var out: [String: Any] = [:]
for (name, rects) in cases {
    out[name] = rects.map { ["x": Double($0.minX), "y": Double($0.minY),
                             "w": Double($0.width), "h": Double($0.height)] }
}
var columns: [String: Int] = [:]
for n in 1...12 { columns["\(n)"] = Layout.preferredColumns(for: n) }

let payload: [String: Any] = ["cases": out, "neighbours": neighbours, "columns": columns]
let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
