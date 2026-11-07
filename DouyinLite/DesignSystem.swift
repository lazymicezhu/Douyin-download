import SwiftUI
import UIKit

// MARK: - Tokens

enum Theme {
    static let corner: CGFloat = 18
    static let gutter: CGFloat = 20
    static var surface: Color { Color(uiColor: .secondarySystemBackground) }
    static var hairline: Color { Color(uiColor: .separator).opacity(0.6) }
}

// MARK: - Buttons

/// Solid ink capsule: black on light, white on dark.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var height: CGFloat = 54

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color(uiColor: .systemBackground))
            .frame(maxWidth: .infinity, minHeight: height)
            .padding(.horizontal, 18)
            .background(Color.primary, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.25)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Quiet filled capsule for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var height: CGFloat = 54
    var fullWidth = false

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(minWidth: height, maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .padding(.horizontal, height > 44 ? 0 : 14)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static func primary(height: CGFloat) -> PrimaryButtonStyle { PrimaryButtonStyle(height: height) }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static func secondary(height: CGFloat) -> SecondaryButtonStyle { SecondaryButtonStyle(height: height) }
    static var secondaryWide: SecondaryButtonStyle { SecondaryButtonStyle(fullWidth: true) }
}

// MARK: - Modifiers

extension View {
    /// Flat rounded surface.
    func surface(padding: CGFloat = 16) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    /// Small uppercase-feeling label above a group.
    func sectionLabel() -> some View {
        self.font(.footnote.weight(.medium)).foregroundStyle(.secondary)
    }

    /// Shows `message` briefly at the bottom of the view, then clears it.
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message {
                Label(message, systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(Color.primary, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(1.8))
                        withAnimation { self.message = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.35), value: message)
        .sensoryFeedback(.success, trigger: message) { _, new in new != nil }
    }
}

// MARK: - Components

/// Inline progress / error line shared by the download and query screens.
struct StatusBanner: View {
    enum Kind { case progress, error }
    let kind: Kind
    let text: String
    var cancel: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if kind == .progress { ProgressView().controlSize(.small) }
            else { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red) }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(kind == .error ? .primary : .secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let cancel {
                Button("取消", action: cancel).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            }
        }
        .surface(padding: 14)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Remote image that always fills the size it is given and never pushes layout wider.
/// Size it from outside (frame / aspectRatio on a container); the image itself is only an overlay.
struct RemoteImage: View {
    let url: URL?

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .tertiarySystemFill))
            .overlay {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else if phase.error != nil || url == nil {
                        Image(systemName: "photo").font(.title3).foregroundStyle(.tertiary)
                    }
                }
            }
            .clipped()
    }
}
