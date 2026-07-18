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
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
            styleMask: [
                .nonactivatingPanel,
                .borderless,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: true)
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 680, height: 520)

        let hosting = NSHostingView(rootView: CompanionView(coordinator: coordinator))
        hosting.sizingOptions = [.minSize, .maxSize]
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
        let width = min(max(680, frame.width * 0.84), 1_100)
        let height = min(max(520, frame.height * 0.86), 860)
        panel.setFrame(
            NSRect(
                x: frame.midX - width / 2,
                y: frame.midY - height / 2,
                width: width,
                height: height),
            display: true)
    }
}
