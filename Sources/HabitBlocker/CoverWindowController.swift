import AppKit

@MainActor
final class CoverWindowController {
    private var panels: [NSPanel] = []

    func setVisible(_ visible: Bool) {
        if visible {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        let screens = NSScreen.screens
        if panels.count != screens.count {
            panels.forEach { $0.orderOut(nil) }
            panels = screens.map { _ in makePanel() }
        }
        for (panel, screen) in zip(panels, screens) {
            panel.setFrame(screen.visibleFrame, display: true)
            panel.orderFrontRegardless()
        }
    }

    private func hide() {
        panels.forEach { $0.orderOut(nil) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = true
        panel.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1)
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let title = NSTextField(labelWithString: "이 화면은 딴짓으로 가려져 있습니다")
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        title.alignment = .center
        title.textColor = NSColor(calibratedWhite: 0.2, alpha: 1)

        let detail = NSTextField(wrappingLabelWithString: "메뉴 막대의 습관 차단기에서 차단을 끄면 이 창이 사라집니다.")
        detail.font = .systemFont(ofSize: 16)
        detail.alignment = .center
        detail.textColor = NSColor(calibratedWhite: 0.35, alpha: 1)
        detail.maximumNumberOfLines = 2

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -32)
        ])
        panel.contentView = content
        return panel
    }
}
