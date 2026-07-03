import AppKit
import SwiftUI

/// The calendar canvas window (Phase 8 SC4 / CALX-04): a vertical time-of-day
/// axis for today rendering calendar events + time-blocked tasks at their
/// `CanvasLayout` positions, plus a draggable unscheduled-tasks rail. Dragging
/// a rail task onto the axis resolves the drop y to a snapped slot Date
/// (`CalendarCanvasModel.slot(atY:)` → `CanvasLayout.slot`) and calls the
/// plan-04 `dropTask(id:atSlot:)` — the visible half of CALX-01.
///
/// OPTIONAL surface (CONTEXT): the menubar dropdown remains the default; this
/// is an alternative view opened on demand. A separate `NSWindow` (RESEARCH A3)
/// rather than a popover — popover drag/focus is fragile.
struct CalendarCanvasView: View {
    /// Forwards the list model's publishes, so every reload (drop write-back,
    /// midnight timer, popover open) re-derives blocks + rail here too.
    @ObservedObject var model: CalendarCanvasModel

    /// True while a drag hovers the axis (subtle targeting highlight).
    @State private var dropTargeted = false

    /// Width of the hour-label gutter on the left of the axis.
    private static let hourLabelWidth: CGFloat = 44
    /// Fixed width of the unscheduled rail column.
    private static let railWidth: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: same date label the menubar shows (shared model).
            HStack {
                Text("Today · \(model.list.dateLabel)")
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                // Time axis: 24h of gridlines + positioned blocks + drop layer,
                // scrolled to the working morning on open.
                ScrollViewReader { proxy in
                    ScrollView {
                        axis
                            .padding(.vertical, 8)
                    }
                    .onAppear { proxy.scrollTo("hour-7", anchor: .top) }
                }

                Divider()

                railView
            }
        }
        .frame(minWidth: 540, minHeight: 480)
        // Drop conflict (T-8-10): the plan-04 continuation seam — Cancel skips
        // the event create (the time: block is already on disk, disk wins);
        // Create anyway commits the event. Double-resolve is structurally
        // impossible (the model nils the continuation before resuming).
        //
        // WR-04: the isPresented setter is INERT — the buttons own the
        // decision (every dismissal path, incl. Esc, routes through the
        // .cancel-role button). A setter that resolved-to-cancel raced the
        // tapped button's action: resolveDropConflict is first-caller-wins,
        // and SwiftUI's setter-vs-action ordering is undocumented, so
        // "Create anyway" could silently become a cancel. Same side-effect-
        // free idiom as the deletePrompt/driftPrompt setters in the menubar.
        // pendingDropConflict is cleared by the model inside
        // resolveDropConflict, which is what flips this binding false.
        .alert("Time conflict",
               isPresented: Binding(
                   get: { model.list.pendingDropConflict != nil },
                   set: { _ in })) {
            Button("Create anyway") { model.list.resolveDropConflict(commitAnyway: true) }
            Button("Cancel", role: .cancel) { model.list.resolveDropConflict(commitAnyway: false) }
        } message: {
            Text("This slot overlaps “\(model.list.pendingDropConflict?.conflictTitle ?? "")”. "
                 + "The task keeps its time either way; Cancel skips creating the calendar event.")
        }
    }

    // MARK: - Time axis

    /// Total axis height: 24 hours at the model's vertical scale.
    private var axisHeight: CGFloat { 24 * model.pixelsPerHour }

    private var axis: some View {
        ZStack(alignment: .topLeading) {
            // Hour gridlines + labels (0…24 so the day is visibly closed).
            ForEach(0..<25, id: \.self) { hour in
                HStack(spacing: 6) {
                    Text(String(format: "%02d:00", hour % 24))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: Self.hourLabelWidth, alignment: .trailing)
                    VStack(spacing: 0) { Divider() }
                }
                .offset(y: CGFloat(hour) * model.pixelsPerHour - 7)
                .id("hour-\(hour)")
            }

            // Positioned blocks: events + time-blocked tasks at their
            // CanvasLayout y/height. Render-only (no hit testing) so drops
            // over a block still land on the drop layer below/above.
            ForEach(model.blocks) { block in
                blockView(block)
                    .allowsHitTesting(false)
            }

            // Drop layer (CALX-01): covers the full 24h axis; y == 0 is exactly
            // dayStart, so `location.y` feeds the tested CanvasLayout.slot math
            // unchanged (T-8-11 — no ad-hoc coordinate→time math here).
            Color.clear
                .frame(height: axisHeight)
                .contentShape(Rectangle())
                .background(dropTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
                .dropDestination(for: String.self) { ids, location in
                    guard let id = ids.first else { return false }
                    model.list.dropTask(id: id, atSlot: model.slot(atY: location.y))
                    return true
                } isTargeted: { dropTargeted = $0 }
        }
        .frame(height: axisHeight, alignment: .top)
    }

    /// One positioned block. Events and tasks are visually DISTINCT: events
    /// render in the accent blue family with a `calendar` glyph, time-blocked
    /// tasks in green with a `checklist` glyph (kind is the tested contract;
    /// the styling hangs off it).
    private func blockView(_ block: CalendarCanvasModel.Block) -> some View {
        let tint: Color = block.kind == .event ? .blue : .green
        return HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: block.kind == .event ? "calendar" : "checklist")
                        .font(.caption2)
                        .foregroundStyle(tint)
                    Text(block.title)
                        .font(.callout)
                        .lineLimit(1)
                }
                // Time range only when the block is tall enough to carry it.
                if block.height >= 34 {
                    Text("\(timeFormatter.string(from: block.start))–\(timeFormatter.string(from: block.end))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, minHeight: block.height, maxHeight: block.height,
               alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .padding(.leading, Self.hourLabelWidth + 12)
        .padding(.trailing, 8)
        .offset(y: block.y)
    }

    // MARK: - Unscheduled rail

    /// The draggable rail: each row drags its task **id** as a bare String
    /// (RESEARCH §Drag-to-time-block — String is Transferable, no custom
    /// UTType; the model re-resolves the Todo on drop).
    private var railView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Unscheduled")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if model.rail.isEmpty {
                Text("Nothing to schedule — every task has a time.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.rail, id: \.id) { task in
                            HStack(spacing: 6) {
                                Image(systemName: "line.3.horizontal")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text(task.text)
                                    .font(.callout)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(Color.secondary.opacity(0.08)))
                            .contentShape(Rectangle())
                            .draggable(task.id)
                            .help("Drag onto the time axis to schedule")
                            .accessibilityLabel("Unscheduled task: \(task.text)")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: Self.railWidth, alignment: .topLeading)
    }

    /// Timezone-pinned HH:mm formatter matching the model's date partitioning
    /// (same idiom as the menubar calendar section).
    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        f.timeZone = model.list.timezone
        return f
    }
}

// MARK: - Window controller

/// The canvas window (RESEARCH A3: a dedicated `NSWindow` over a popover —
/// popover drag/focus is fragile). Mirrors the Settings/Capture window idiom:
/// an `NSHostingController`-backed window, accessory-activation friendly
/// (`show()` activates the app explicitly, same as Settings).
@MainActor
final class CalendarCanvasWindowController: NSWindowController {
    /// Wraps the SHARED menubar list model (same store/calendar/now()), so the
    /// canvas sees exactly what the dropdown sees and a drop's trailing reload
    /// refreshes both surfaces.
    init(list: MenubarListModel) {
        let host = NSHostingController(
            rootView: CalendarCanvasView(model: CalendarCanvasModel(list: list)))
        let win = NSWindow(contentViewController: host)
        win.title = "Jotty — Calendar Canvas"
        win.styleMask = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 560, height: 620))
        super.init(window: win)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
