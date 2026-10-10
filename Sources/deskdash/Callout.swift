import AppKit
import SwiftUI

/// A card in the top-right corner of the main screen, for `alerts.card`: what needs you, which stays until it is over or
/// you close it. A notification's banner leaves after a few seconds unless someone sets its style to Persistent in
/// System Settings; this does not depend on that. It never takes focus, and its × closes it.
@MainActor
final class Callout {
    @MainActor @Observable
    final class Model {
        var kind = Chime.Kind.waiting
        var title = ""
        var body = ""
    }

    private let model = Model()
    private var panel: NSPanel?
    private(set) var shown = false

    func show(_ kind: Chime.Kind, title: String, body: String) {
        model.kind = kind
        model.title = title
        model.body = body
        let panel = panel ?? makePanel()
        self.panel = panel
        place(panel)
        panel.orderFrontRegardless()
        shown = true
    }

    func hide() {
        panel?.orderOut(nil)
        shown = false
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: CalloutView.width, height: 96),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: CalloutView(model: model) { [weak self] in self?.hide() })
        return panel
    }

    /// Below the menu bar at the right of the main screen, where notifications come in.
    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first else { return }
        let size = panel.contentView?.fittingSize ?? NSSize(width: CalloutView.width, height: 96)
        let area = screen.visibleFrame
        panel.setFrame(NSRect(x: area.maxX - size.width - 14, y: area.maxY - size.height - 14,
                              width: size.width, height: size.height), display: true)
    }
}

struct CalloutView: View {
    static let width: CGFloat = 380

    let model: Callout.Model
    let close: () -> Void

    var body: some View {
        let color: Color = switch model.kind {
        case .waiting: Theme.waiting
        case .done: Theme.up
        case .limit: Theme.down
        }
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(color).frame(width: 12, height: 12).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title).font(.system(size: 15, weight: .semibold))
                if !model.body.isEmpty {
                    Text(model.body).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(color.opacity(0.7), lineWidth: 2))
    }
}
