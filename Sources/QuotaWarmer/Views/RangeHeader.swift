import SwiftUI

/// First row of the Cache, Cost and History tabs: a `‹ window ›` navigator
/// on the left and one pill on the right that cycles the range length.
struct RangeHeader: View {
    /// nil hides the navigator (Cost's All shows `fixedLabel` instead).
    let window: RangeWindow?
    var fixedLabel: String? = nil
    var canGoBack = false
    var partialNote: String? = nil
    let pillLabel: String
    let pillHelp: String
    let onStep: (Int) -> Void
    let onCycle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let window {
                stepButton("chevron.left", enabled: canGoBack, help: "Earlier") { onStep(window.offset + 1) }
                Text(verbatim: window.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.C.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                stepButton("chevron.right", enabled: !window.isCurrent, help: "Later") { onStep(window.offset - 1) }
                if !window.isCurrent {
                    Button { onStep(0) } label: {
                        Text("Now")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DS.C.text)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .overlay(Capsule().stroke(DS.C.border, lineWidth: 1))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Back to the current window")
                }
                if let partialNote {
                    Text("partial")
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.C.textMuted)
                        .underline(pattern: .dot)
                        .help(partialNote)
                }
            } else if let fixedLabel {
                Text(verbatim: fixedLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.C.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(action: onCycle) {
                Text(verbatim: pillLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.C.text)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(DS.C.surfaceHigh, in: Capsule())
                    .overlay(Capsule().stroke(DS.C.border, lineWidth: 1))
            }
            .buttonStyle(PressableButtonStyle())
            .help(pillHelp)
            .accessibilityLabel(Text(verbatim: pillHelp))
        }
        .frame(height: DS.Page.headerHeight)
    }

    private func stepButton(_ symbol: String, enabled: Bool, help: LocalizedStringKey,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 20)
                .foregroundStyle(enabled ? DS.C.text : DS.C.textMuted.opacity(0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled)
        .help(help)
    }
}

/// A small "?" that explains a number on hover.
struct HelpMark: View {
    let text: String

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 9))
            .foregroundStyle(DS.C.textMuted)
            .help(text)
            .accessibilityLabel(Text(verbatim: text))
    }
}
