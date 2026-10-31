import Foundation
import CoreGraphics
import AppKit

@_silgen_name("smoose_post_native_swipe")
func smoose_post_native_swipe(_ direction: Int32)

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
            // 优先投递原生触控板轻扫手势（左滑 4，在 Safari/Chrome/Finder 中触发平滑跟手翻页）
            // 替代容易与文本输入框光标冲突的 Cmd+[
            smoose_post_native_swipe(4)
        case .forward:
            // 优先投递原生触控板轻扫手势（右滑 8，触发平滑前进）
            smoose_post_native_swipe(8)
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
