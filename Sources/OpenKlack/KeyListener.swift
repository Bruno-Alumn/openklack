import AppKit

/// Global keyboard/mouse observer built on NSEvent monitors (requires the
/// Accessibility permission, same as Klack). Local monitors cover events while
/// our own UI is frontmost.
final class KeyListener {
    enum Event {
        case keyDown(keycode: UInt16, isRepeat: Bool)
        case keyUp(keycode: UInt16)
        case mouseDown
        case mouseUp
    }

    var handler: ((Event) -> Void)?

    private var monitors: [Any] = []
    private var downModifiers = Set<UInt16>()

    func start() {
        stop()
        let keyMask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp,
                                                .rightMouseDown, .rightMouseUp,
                                                .otherMouseDown, .otherMouseUp]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: keyMask) { [weak self] event in
            self?.process(event)
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in
            self?.process(event)
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: keyMask) { [weak self] event in
            self?.process(event)
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in
            self?.process(event)
            return event
        } as Any)
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        downModifiers.removeAll()
    }

    private func process(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            handler?(.keyDown(keycode: event.keyCode, isRepeat: event.isARepeat))
        case .keyUp:
            handler?(.keyUp(keycode: event.keyCode))
        case .flagsChanged:
            // NSEvent gives no press/release direction for modifiers; track
            // per-keycode state so each physical modifier gets both strokes.
            let code = event.keyCode
            if downModifiers.contains(code) {
                downModifiers.remove(code)
                handler?(.keyUp(keycode: code))
            } else {
                downModifiers.insert(code)
                handler?(.keyDown(keycode: code, isRepeat: false))
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            handler?(.mouseDown)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            handler?(.mouseUp)
        default:
            break
        }
    }
}

enum Permissions {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestIfNeeded() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
