import SwiftUI

/// Adds click-and-drag scrolling to SwiftUI's horizontal ScrollView on macOS.
/// Trackpad and mouse-wheel scrolling continue to use the native ScrollView.
@MainActor
private struct HorizontalMouseDragModifier: ViewModifier {
    @State private var scrollPosition = ScrollPosition()
    @State private var currentOffset: CGFloat = 0
    @State private var startingOffset: CGFloat?
    @State private var isHorizontalDrag: Bool?

    func body(content: Content) -> some View {
        content
            .scrollPosition($scrollPosition)
            .contentShape(Rectangle())
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, newOffset in
                currentOffset = newOffset
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .local)
                    .onChanged { value in
                        if isHorizontalDrag == nil {
                            isHorizontalDrag = abs(value.translation.width) > abs(value.translation.height)
                        }
                        guard isHorizontalDrag == true else { return }
                        if startingOffset == nil { startingOffset = currentOffset }
                        scrollPosition.scrollTo(
                            x: max(0, (startingOffset ?? currentOffset) - value.translation.width)
                        )
                    }
                    .onEnded { _ in resetDrag() }
            )
            .onDisappear { resetDrag() }
    }

    private func resetDrag() {
        startingOffset = nil
        isHorizontalDrag = nil
    }
}

extension View {
    @MainActor
    func mouseDraggableHorizontalScroll() -> some View {
        modifier(HorizontalMouseDragModifier())
    }
}
