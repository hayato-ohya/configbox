import SwiftUI
import AppKit

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Simple wrapping layout (rows fill left to right, centered).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = layoutRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layoutRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for i in row.indices {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func layoutRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, sv) in subviews.enumerated() {
            let s = sv.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            let extra = row.indices.isEmpty ? s.width : s.width + spacing
            if !row.indices.isEmpty && row.width + extra > maxWidth {
                rows.append(Row(indices: [i], width: s.width, height: s.height))
            } else {
                row.indices.append(i); row.width += extra; row.height = max(row.height, s.height)
                rows[rows.count - 1] = row
            }
        }
        return rows
    }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    var onHover: (Int) -> Void
    var onClick: (Int) -> Void
    var onCancel: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { onCancel() }

                FlowLayout(spacing: 6) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                        WindowCell(item: item,
                                   height: CGFloat(model.settings.thumbnailHeight),
                                   selected: i == model.selected,
                                   showTitle: model.settings.showTitles)
                            .onHover { if $0 { onHover(i) } }
                            .onTapGesture { onClick(i) }
                    }
                }
                .padding(14)
                .frame(maxWidth: geo.size.width * 0.85)
                .background(VisualEffectView(material: .hudWindow))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
                .fixedSize()
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}

struct WindowCell: View {
    @ObservedObject var item: WindowItem
    let height: CGFloat
    let selected: Bool
    let showTitle: Bool

    private var width: CGFloat { min(max(height * item.aspect, height * 0.7), height * 1.9) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let t = item.thumbnail {
                        Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else if let icon = item.icon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: height * 0.5, height: height * 0.5)
                    }
                }
                .frame(width: width, height: height)
                .opacity(item.isMinimized || item.isHidden ? 0.5 : 1)

                if item.thumbnail != nil, let icon = item.icon {
                    Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                        .shadow(radius: 3).offset(x: 6, y: 6)
                }
                if item.isMinimized {
                    Image(systemName: "arrow.down.right.and.arrow.up.left.circle.fill")
                        .font(.system(size: 16)).foregroundStyle(.secondary).offset(x: 6, y: -height + 10)
                }
            }
            if showTitle {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: width)
                    .foregroundStyle(.primary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.18) : .clear)
        )
        .contentShape(Rectangle())
    }
}
