import SwiftUI

// MARK: - Containers

struct Card<Content: View>: View {
    var padding: CGFloat? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding ?? 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

struct RowDivider: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}

struct Eyebrow: View {
    let text: String
    var color: Color = Theme.accentText
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.5)
            .foregroundColor(color)
    }
}

/// A tappable card row that drills into another card.
struct NavRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var action: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(Theme.text)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12)).foregroundColor(Theme.sub).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                trailing
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.faint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension NavRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, action: action) { EmptyView() }
    }
}

// MARK: - Override pills

struct PillsView: View {
    let states: [PillState]
    var width: CGFloat = 26

    private static let gap: CGFloat = 5
    private static let height: CGFloat = 6

    /// Width when every pill gets its preferred `width`; never more than that is requested.
    private var idealWidth: CGFloat {
        CGFloat(PillLayout.totalWidth(pillWidth: Double(width), count: states.count, gap: Double(Self.gap)))
    }

    var body: some View {
        // Takes min(proposed, ideal) width, so a large count can never widen its container;
        // the Canvas then shrinks the pills (or falls back to one segmented bar) to fit.
        CappedWidthLayout(ideal: idealWidth, height: Self.height) {
            Canvas { ctx, size in draw(in: &ctx, size: size) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let count = states.count
        guard count > 0, size.width > 0 else { return }
        let h = size.height
        if let w = PillLayout.pillWidth(preferred: Double(width), available: Double(size.width), count: count, gap: Double(Self.gap)) {
            let pw = CGFloat(w)
            for (i, state) in states.enumerated() {
                let rect = CGRect(x: CGFloat(i) * (pw + Self.gap), y: 0, width: pw, height: h)
                drawPill(state, in: rect, ctx: &ctx)
            }
        } else {
            // Too narrow for separate pills: one capsule bar split into segments by 1pt gaps.
            let segGap: CGFloat = 1
            let sw = max(0, (size.width - segGap * CGFloat(count - 1)) / CGFloat(count))
            var bar = ctx
            bar.clip(to: Capsule().path(in: CGRect(origin: .zero, size: size)))
            for (i, state) in states.enumerated() {
                let rect = CGRect(x: CGFloat(i) * (sw + segGap), y: 0, width: sw, height: h)
                drawSegment(state, in: rect, ctx: &bar)
            }
        }
    }

    private func drawPill(_ state: PillState, in rect: CGRect, ctx: inout GraphicsContext) {
        let shape = Capsule().path(in: rect)
        switch state {
        case .available:
            ctx.fill(shape, with: .color(Theme.green))
        case .used:
            ctx.fill(shape, with: .color(Theme.track))
        case .using(let fraction):
            var inner = ctx
            inner.clip(to: shape)
            inner.fill(Path(rect), with: .color(Theme.greenTrack))
            inner.fill(Capsule().path(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height)), with: .color(Theme.green))
        case .pending:
            ctx.stroke(Capsule().path(in: rect.insetBy(dx: 0.75, dy: 0.75)), with: .color(Theme.green), lineWidth: 1.5)
        }
    }

    private func drawSegment(_ state: PillState, in rect: CGRect, ctx: inout GraphicsContext) {
        switch state {
        case .available:
            ctx.fill(Path(rect), with: .color(Theme.green))
        case .used:
            ctx.fill(Path(rect), with: .color(Theme.track))
        case .using(let fraction):
            ctx.fill(Path(rect), with: .color(Theme.greenTrack))
            ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height)), with: .color(Theme.green))
        case .pending:
            ctx.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(Theme.green), lineWidth: 1)
        }
    }

    private var accessibilityText: String {
        let available = states.filter { $0 == .available }.count
        return String(format: NSLocalizedString("%ld of %ld overrides available", comment: "pills a11y"), available, states.count)
    }
}

/// Sizes its single child to min(proposed width, `ideal`) x `height`.
/// Reports `ideal` (not more) when the proposal is unspecified.
private struct CappedWidthLayout: Layout {
    let ideal: CGFloat
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposed = proposal.width ?? ideal
        return CGSize(width: max(0, min(proposed, ideal)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews { s.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(Theme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 30
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(isEnabled ? Theme.text : Theme.faint)
            .padding(.horizontal, 14)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background((isEnabled ? Theme.cardRaised : Color(hex: 0x33333A)).opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
    }
}

struct ChipButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundColor(selected ? Theme.chipSelectedText : Theme.sub)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(selected ? Theme.chipSelected : Color.clear)
            .overlay(Capsule().strokeBorder(selected ? Theme.chipSelectedBorder : Color.clear, lineWidth: 1))
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

struct LinkButtonStyle: ButtonStyle {
    var color: Color = Theme.sub
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundColor(color.opacity(configuration.isPressed ? 0.7 : 1))
            .underline()
            .padding(4)
            .contentShape(Rectangle())
    }
}

// MARK: - Switch

struct SCSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                configuration.label
                Spacer(minLength: 8)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Theme.accent : Color(hex: 0x48484F)).frame(width: 32, height: 20)
                    Circle().fill(Color.white).frame(width: 16, height: 16).padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? Text("On") : Text("Off"))
    }
}

// MARK: - Radio rows (either/or choices are ALWAYS radio groups - spec §5)

struct RadioRow: View {
    let title: String
    let subtitle: String
    let selected: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().strokeBorder(selected ? Theme.accent : Theme.fieldBorder, lineWidth: 1.5).frame(width: 16, height: 16)
                    if selected { Circle().fill(Theme.accent).frame(width: 8, height: 8) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: selected ? .semibold : .medium)).foregroundColor(Theme.text)
                    Text(subtitle).font(.system(size: 11)).foregroundColor(Theme.sub)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Progress bar

struct ProgressBar: View {
    let fraction: Double
    var tint: Color = Theme.accent
    var track: Color = Theme.track
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Duration slider (custom track + white knob, piecewise scale)

extension View {
    /// Hides the blue keyboard-focus ring, which otherwise lingers on whatever row or button
    /// last took focus. Keyboard shortcuts and Tab still work. macOS 13 falls back to the
    /// per-control `.focusable(false)` calls.
    @ViewBuilder func noFocusRing() -> some View {
        if #available(macOS 14.0, *) { focusEffectDisabled() } else { self }
    }
}

struct DurationSlider: View {
    @Binding var minutes: Int
    let scale: DurationScale
    var tint: Color = Theme.accent

    static let knobSize: CGFloat = 22

    /// Knob centre for a scale position. The centre travels between the two
    /// knob radii, so it sits exactly over a tick drawn at the same x.
    static func knobCenterX(position: Double, width: CGFloat) -> CGFloat {
        let r = knobSize / 2
        return r + CGFloat(min(max(position, 0), 1)) * max(0, width - knobSize)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let center = Self.knobCenterX(position: scale.position(for: minutes), width: width)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track).frame(height: 4)
                Capsule().fill(tint).frame(width: center, height: 4)
                Circle()
                    .fill(Color(hex: 0xF5F5F7))
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
                    .offset(x: center - Self.knobSize / 2)
            }
            .frame(height: Self.knobSize)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let travel = width - Self.knobSize
                guard travel > 0 else { return }
                let p = Double((value.location.x - Self.knobSize / 2) / travel)
                minutes = scale.minutes(at: min(max(p, 0), 1))
            })
        }
        .frame(height: Self.knobSize)
        .accessibilityElement()
        .accessibilityLabel(Text("Duration"))
        .accessibilityValue(Text(DurationText.short(minutes: minutes)))
        .accessibilityAdjustableAction { direction in
            let p = scale.position(for: minutes)
            switch direction {
            case .increment: minutes = scale.minutes(at: min(1, p + 0.02))
            case .decrement: minutes = scale.minutes(at: max(0, p - 0.02))
            @unknown default: break
            }
        }
    }
}

// MARK: - Stepper

struct CompactStepper: View {
    let value: String
    let label: String
    let canDecrement: Bool
    let canIncrement: Bool
    let decrement: () -> Void
    let increment: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: decrement) { Text("−").frame(width: 30, height: 28).contentShape(Rectangle()) }
                .buttonStyle(.plain).disabled(!canDecrement)
                .accessibilityLabel(Text("Decrease \(label)"))
            Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit()).frame(minWidth: 28)
            Button(action: increment) { Text("+").frame(width: 30, height: 28).contentShape(Rectangle()) }
                .buttonStyle(.plain).disabled(!canIncrement)
                .accessibilityLabel(Text("Increase \(label)"))
        }
        .font(.system(size: 15))
        .foregroundColor(Theme.text)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.fieldBorder, lineWidth: 1))
    }
}

// MARK: - Text field

struct SCTextField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Theme.field)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.fieldBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onSubmit(onSubmit)
    }
}
