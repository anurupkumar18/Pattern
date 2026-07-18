import AppKit
import CoreGraphics
import VoiceOpsCore

/// Escape is observed below the model/sidecar loop. While armed, the CGEvent
/// tap consumes Escape and schedules cancellation on the main actor. A global
/// monitor remains as a non-consuming fallback when macOS denies event taps.
@MainActor
final class PanicStopMonitor {
    private final class ArmedState: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set(_ newValue: Bool) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func get() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private nonisolated(unsafe) var globalMonitor: Any?
    private let armedState = ArmedState()
    private let onStop: @MainActor () -> Void

    init(onStop: @escaping @MainActor () -> Void) {
        self.onStop = onStop
        install()
    }

    func setArmed(_ armed: Bool) {
        armedState.set(armed)
        if armed, eventTap == nil, installEventTap(), let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: armed) }
    }

    private func install() {
        if !installEventTap() { installFallbackMonitor() }
    }

    @discardableResult
    private func installEventTap() -> Bool {
        guard eventTap == nil else { return true }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userData in
                guard let userData else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<PanicStopMonitor>
                    .fromOpaque(userData).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: monitor.armedState.get())
                    }
                    return Unmanaged.passUnretained(event)
                }
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                guard PanicStopPolicy.shouldCancel(
                    keyCode: keyCode, isArmed: monitor.armedState.get())
                else { return Unmanaged.passUnretained(event) }
                DispatchQueue.main.async { [weak monitor] in monitor?.onStop() }
                return nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())

        if let eventTap {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: false)
            return true
        }
        return false
    }

    private func installFallbackMonitor() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self,
                  PanicStopPolicy.shouldCancel(
                    keyCode: Int64(event.keyCode), isArmed: self.armedState.get())
            else { return }
            Task { @MainActor [weak self] in self?.onStop() }
        }
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }
}
