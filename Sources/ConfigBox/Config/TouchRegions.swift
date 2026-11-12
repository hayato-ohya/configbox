import Foundation
import CoreGraphics

/// A part of the trackpad a gesture can be limited to. Coordinates are the multitouch ones: 0…1 on both
/// axes, origin at the bottom left. Corners and edges are `size` of the width deep; vertically the depth is
/// scaled by the pad's aspect ratio so a corner is about square on the real trackpad.
enum TouchRegion: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    case topEdge, bottomEdge, leftEdge, rightEdge
    case leftHalf, rightHalf, topHalf, bottomHalf
    case center

    var id: String { rawValue }

    static let corners: [TouchRegion] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    static let edges: [TouchRegion] = [.topEdge, .bottomEdge, .leftEdge, .rightEdge]
    static let halves: [TouchRegion] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]

    /// Width / height of Apple trackpads (about 16 × 10 cm and similar).
    static let aspect: CGFloat = 1.6
    static let defaultSize = 0.15

    var title: String {
        switch self {
        case .topLeft: L("Top-left corner")
        case .topRight: L("Top-right corner")
        case .bottomLeft: L("Bottom-left corner")
        case .bottomRight: L("Bottom-right corner")
        case .topEdge: L("Top edge")
        case .bottomEdge: L("Bottom edge")
        case .leftEdge: L("Left edge")
        case .rightEdge: L("Right edge")
        case .leftHalf: L("Left half")
        case .rightHalf: L("Right half")
        case .topHalf: L("Top half")
        case .bottomHalf: L("Bottom half")
        case .center: L("Center (away from the edges)")
        }
    }

    /// Higher = narrower. When several triggers match, the most specific one wins.
    var specificity: Int {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: 3
        case .topEdge, .bottomEdge, .leftEdge, .rightEdge, .center: 2
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: 1
        }
    }

    /// The region in trackpad coordinates for a corner / edge depth of `size` (fraction of the width).
    func rect(size: Double) -> CGRect {
        let dx = CGFloat(min(max(size, 0.02), 0.5))
        let dy = min(dx * Self.aspect, 0.5)
        switch self {
        case .topLeft: return CGRect(x: 0, y: 1 - dy, width: dx, height: dy)
        case .topRight: return CGRect(x: 1 - dx, y: 1 - dy, width: dx, height: dy)
        case .bottomLeft: return CGRect(x: 0, y: 0, width: dx, height: dy)
        case .bottomRight: return CGRect(x: 1 - dx, y: 0, width: dx, height: dy)
        case .topEdge: return CGRect(x: 0, y: 1 - dy, width: 1, height: dy)
        case .bottomEdge: return CGRect(x: 0, y: 0, width: 1, height: dy)
        case .leftEdge: return CGRect(x: 0, y: 0, width: dx, height: 1)
        case .rightEdge: return CGRect(x: 1 - dx, y: 0, width: dx, height: 1)
        case .leftHalf: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .bottomHalf: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .center: return CGRect(x: dx, y: dy, width: 1 - 2 * dx, height: 1 - 2 * dy)
        }
    }

    /// Edges of the pad count as inside, so a finger right on the border still hits a corner.
    func contains(_ p: CGPoint, size: Double) -> Bool {
        let r = rect(size: size)
        return p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY
    }
}

/// One finger of a recognized gesture.
struct TouchSample: Equatable {
    var start: CGPoint        // where it landed
    var position: CGPoint     // where it is (or was when it lifted)
    var landed: Double        // multitouch timestamp of the landing
    var moved: Float          // farthest it travelled from `start`
}

/// What the trackpad engine saw, before it is matched against the triggers.
struct GestureInput {
    var kind: GestureKind
    /// The fingers doing the gesture. For an anchored tap these are the ones that tapped.
    var touches: [TouchSample]
    /// Fingers that stayed down while the others tapped (anchored taps only).
    var resting: [TouchSample] = []

    /// A plain gesture for display and logging.
    var gesture: Gesture { Gesture(fingers: touches.count, kind: kind) }
}

/// Decides whether a trigger's gesture matches what the trackpad saw.
enum GestureMatcher {
    /// A resting finger must have been down this long before the others landed.
    static let restLead: Double = 0.15
    /// …and may not have moved more than this (normalized units).
    static let restMovement: Float = 0.03

    /// nil = no match; otherwise higher = more specific.
    static func score(_ g: Gesture, _ input: GestureInput, size: Double) -> Int? {
        guard g.kind == input.kind else { return nil }
        // One finger anywhere would be every ordinary tap or click; one-finger swipes are pointer movement.
        if g.fingers == 1 && ((g.region == nil && g.anchor == nil) || !g.kind.isStationary) { return nil }
        let swipe = !g.kind.isStationary
        func point(_ t: TouchSample) -> CGPoint { swipe ? t.start : t.position }
        func centroid(_ ts: [TouchSample]) -> CGPoint {
            let n = CGFloat(ts.count)
            return CGPoint(x: ts.reduce(0) { $0 + point($1).x } / n, y: ts.reduce(0) { $0 + point($1).y } / n)
        }
        func regionScore(_ acting: [TouchSample]) -> Int? {
            guard acting.count == g.fingers, !acting.isEmpty else { return nil }
            guard let region = g.region else { return 0 }
            return region.contains(centroid(acting), size: size) ? region.specificity * 10 : nil
        }

        guard let anchor = g.anchor else {
            return input.resting.isEmpty ? regionScore(input.touches) : nil
        }
        guard g.kind.allowsAnchor else { return nil }
        let bonus = 5 + anchor.specificity
        if !input.resting.isEmpty {
            // An anchored tap: the engine already split the fingers.
            guard input.resting.count == 1, anchor.contains(input.resting[0].position, size: size) else { return nil }
            return regionScore(input.touches).map { $0 + bonus }
        }
        // A click: one of the fingers on the pad must be the resting one.
        for (i, r) in input.touches.enumerated() where r.moved <= restMovement && anchor.contains(r.position, size: size) {
            var others = input.touches
            others.remove(at: i)
            guard let firstOther = others.map(\.landed).min(), r.landed <= firstOther - restLead else { continue }
            if let s = regionScore(others) { return s + bonus }
        }
        return nil
    }

    /// Whether any of `gestures` could match `input` (used by the engine to decide what to wait for).
    static func anyMatch(_ gestures: [Gesture], _ input: GestureInput, size: Double) -> Bool {
        gestures.contains { score($0, input, size: size) != nil }
    }
}
