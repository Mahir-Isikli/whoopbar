import SwiftUI

/// Native SwiftUI port of the fluidfunctionalism animated tabs: a selected "pill" that
/// springs/slides between items (via matchedGeometryEffect, the SwiftUI analogue of
/// framer-motion's layout animation) plus a faster, subtler hover preview indicator.
struct FluidTabBar<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String
    let accent: (T) -> Color
    var showTrack: Bool = true
    let pal: Pal

    @Environment(\.colorScheme) private var scheme
    @Namespace private var ns
    @State private var hovered: T?

    // Spring feel matched to the source component (moderate for select, fast for hover).
    private let selectSpring = Animation.spring(response: 0.34, dampingFraction: 0.72)
    private let hoverSpring  = Animation.spring(response: 0.22, dampingFraction: 0.86)

    var body: some View {
        HStack(spacing: 1) {
            ForEach(items, id: \.self) { item in
                let isSel = item == selection
                Text(label(item))
                    .font(.system(size: 12, weight: isSel ? .semibold : .medium))
                    .foregroundStyle(isSel ? accent(item) : Color.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background {
                        ZStack {
                            if isSel {
                                Capsule().fill(accent(item).opacity(scheme == .dark ? 0.28 : 0.16))
                                    .matchedGeometryEffect(id: "active", in: ns)
                            } else if hovered == item {
                                Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.05))
                                    .matchedGeometryEffect(id: "hover", in: ns)
                            }
                        }
                    }
                    .contentShape(Capsule())
                    .onHover { h in
                        withAnimation(hoverSpring) {
                            if h { hovered = item } else if hovered == item { hovered = nil }
                        }
                    }
                    .onTapGesture {
                        withAnimation(selectSpring) { selection = item }
                    }
            }
        }
        .padding(showTrack ? 3 : 0)
        .background {
            if showTrack { Capsule().fill(pal.pillRest.opacity(0.7)) }
        }
    }
}
