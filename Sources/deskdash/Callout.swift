import AppKit
import SwiftUI

/// The alert card (`alerts.card`) floating at the dock screen's top right, for while windows are on the dock screen and
/// the dashboard, which otherwise draws the card itself, stays behind them. It never takes focus, and its × closes it.
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
    var onClose: (() -> Void)?

    /// So the dashboard does not count the card as a window it has to stay behind.
    var windowNumber: Int { panel?.windowNumber ?? -1 }

    func show(_ kind: Chime.Kind, title: String, body: String, on screen: NSScreen) {
        model.kind = kind
        model.title = title
        model.body = body
        let panel = panel ?? makePanel()
        self.panel = panel
        place(panel, on: screen)
        if !shown { panel.orderFrontRegardless() }
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
        panel.contentView = NSHostingView(rootView: CalloutView(model: model) { [weak self] in
            self?.hide()
            self?.onClose?()
        })
        return panel
    }

    /// The dock screen's top right corner.
    private func place(_ panel: NSPanel, on screen: NSScreen) {
        let size = panel.contentView?.fittingSize ?? NSSize(width: CalloutView.width, height: 96)
        let area = screen.visibleFrame
        let frame = NSRect(x: area.maxX - size.width - 14, y: area.maxY - size.height - 14, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
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
            .help(L10n.t("Close"))
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(color.opacity(0.7), lineWidth: 2))
    }
}
