import Foundation
import CoreGraphics
import AppKit

enum ActionRunner {
    static func run(_ action: ButtonAction) {
        switch action {
        case .none:
            break
        case .missionControl:
            open("/System/Applications/Mission Control.app")
        case .launchpad:
            open("/System/Applications/Launchpad.app")
        case .appSwitcher:
            tap(keyCode: 48, flags: .maskCommand)
        case .showDesktop:
            tap(keyCode: 103, flags: .maskSecondaryFn)
        case .back:
            tap(keyCode: 33, flags: .maskCommand)
        case .forward:
            tap(keyCode: 30, flags: .maskCommand)
        case .spaceLeft:
            tap(keyCode: 123, flags: .maskControl)
        case .spaceRight:
            tap(keyCode: 124, flags: .maskControl)
        case .appExpose:
            tap(keyCode: 125, flags: .maskControl)
        case .screenshot:
            tap(keyCode: 23, flags: [.maskCommand, .maskShift])
        case .copy:
            tap(keyCode: 8, flags: .maskCommand)
        case .paste:
            tap(keyCode: 9, flags: .maskCommand)
        }
    }

    private static func open(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }

    private static func tap(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }
}
