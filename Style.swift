import AppKit
import SwiftUI

/// Shared look of the overview window: translucent sidebar, cards, tab chips, stat tiles.

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

extension View {
    /// Rounded card with a hairline border; a tint colors border and background slightly.
    func card(_ tint: Color? = nil, padding: CGFloat = 12, radius: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill((tint ?? .clear).opacity(0.07)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(tint.map { $0.opacity(0.45) } ?? Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
    }
}

/// Tab as a capsule with icon and optional counter badge.
struct TabChip: View {
    let icon: String
    let title: String
    var count = 0
    var alert = false
    let selected: Bool
    let action: () -> Void
    @SwiftUI.State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(alert ? Color.orange : selected ? Color.white.opacity(0.25) : Color.primary.opacity(0.1)))
                        .foregroundStyle(alert ? Color.white : selected ? Color.white : Color.secondary)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(Capsule().fill(selected ? Color.accentColor : hover ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Small filter capsule (e.g. „Rückfragen“).
struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

/// Key figure: colored symbol, big number, label.
struct StatTile: View {
    let icon: String
    let value: String
    let label: String
    var tint = Color.accentColor
    var alert = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .card(alert ? tint : nil, padding: 10)
    }
}

/// Colored status capsule („arbeitet seit 12 min“).
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .medium))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
        .foregroundStyle(color)
    }
}

/// Section heading in small caps with a count.
struct SectionTitle: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.8)
            if let count { Text("\(count)").font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(.tertiary) }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
