import AppKit
import SwiftUI

/// Borderless panel that can still take keyboard focus so Stop/Escape work.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Floating companion near the top of the screen (PRD §9: lives near the
/// work, never a big chat window). Non-activating: it must not steal focus
/// from the app the user is talking about.
@MainActor
final class CompanionPanelController {
    private let panel: KeyablePanel

    init(coordinator: AppCoordinator) {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: CompanionView(coordinator: coordinator))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
    }

    func show() {
        if !panel.isVisible { position() }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameTopLeftPoint(
            NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - 24))
    }
}
