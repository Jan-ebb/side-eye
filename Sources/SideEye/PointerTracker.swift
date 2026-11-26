import SwiftUI

/// What the pointer can be over in the sidebar.
enum PointerRegion: Hashable {
    case row(String)
    case paletteEntry(Int)
    /// A band that lies over rows, as a pinned group header does: the pointer on it is on no row.
    case cover(String)
}

/// Says which part of the sidebar the pointer is over. SwiftUI's own hover is not used for this: it
/// depends on the app or the window being active, and the sidebar is a panel of an app that stays in
/// the background, where hover does not report on every Mac. The window's own tracking area, which is
/// always active, says where the pointer is, and the rows say where they are.
@MainActor
final class PointerTracker: ObservableObject {
    /// The row or entry under the pointer. It changes when the pointer moves, and for a moment after a
    /// scroll. A list that shifts under a resting pointer for any other reason selects nothing.
    @Published private(set) var region: PointerRegion?
    /// Whether the command palette is what the sidebar shows. Its entries and the chat rows are never
    /// pointed at together, even if one of them is slow to leave.
    var showsPalette: () -> Bool = { false }

    private struct Entry {
        var frame: CGRect
        var owner: UUID
    }
    private var frames: [PointerRegion: Entry] = [:]
    /// The part of the sidebar a list shows through. A row scrolled out of it cannot be pointed at.
    private var viewport: Entry?
    private var location: CGPoint?
    private var scrolledAt = Date.distantPast

    /// Where the pointer is, measured from the sidebar's top-left corner, or nil once it has left.
    func move(to point: CGPoint?) {
        location = point
        update()
    }

    /// Scrolling moves rows under the pointer, so for a moment their new places count.
    func scrolled(at time: Date = Date()) {
        scrolledAt = time
    }

    /// A view reports where it is, or nil when it goes. Only the view that last reported a region can
    /// take it away, so a row that is rebuilt does not erase its own successor.
    func setFrame(_ frame: CGRect?, for region: PointerRegion, owner: UUID, now: Date = Date()) {
        if let frame { frames[region] = Entry(frame: frame, owner: owner) }
        else if frames[region]?.owner == owner { frames[region] = nil }
        if now.timeIntervalSince(scrolledAt) < 0.3 { update() }
    }

    func setViewport(_ frame: CGRect?, owner: UUID) {
        if let frame { viewport = Entry(frame: frame, owner: owner) }
        else if viewport?.owner == owner { viewport = nil }
    }

    /// Where a region last said it is, for the on-screen check that points at a row.
    func frame(for region: PointerRegion) -> CGRect? { frames[region]?.frame }

    private func update() {
        let hit = location.flatMap(region(at:))
        if hit != region { region = hit }
    }

    func region(at point: CGPoint) -> PointerRegion? {
        guard viewport?.frame.contains(point) ?? true else { return nil }
        let inPalette = showsPalette()
        var found: PointerRegion?
        for (region, entry) in frames where entry.frame.contains(point) {
            switch region {
            case .paletteEntry: if inPalette { found = region }
            case .row: if !inPalette { found = region }
            case .cover: if !inPalette { return nil }
            }
        }
        return found
    }
}

/// Reports a view's place in the window to the tracker, and its going.
private struct PointerFrame: ViewModifier {
    let report: (CGRect?, UUID) -> Void
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .global)
                Color.clear
                    .onAppear { report(frame, owner) }
                    .onChange(of: frame) { _, frame in report(frame, owner) }
                    .onDisappear { report(nil, owner) }
            }
        }
    }
}

extension View {
    /// Makes this view something the pointer can be over.
    func pointerRegion(_ region: PointerRegion, in tracker: PointerTracker) -> some View {
        modifier(PointerFrame { frame, owner in tracker.setFrame(frame, for: region, owner: owner) })
    }

    /// Marks this view as the opening its list shows through.
    func pointerViewport(in tracker: PointerTracker) -> some View {
        modifier(PointerFrame { frame, owner in tracker.setViewport(frame, owner: owner) })
    }
}
