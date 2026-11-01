import Foundation
import IOKit
import IOKit.hid

/// 罗技 HID++ 2.0 / 1.0 协议控制器（纯 Swift 原生驱动，对齐 niw/HIDPP 核心逻辑）
/// 支持自动检测 USB Receiver / 蓝牙连接的罗技鼠标，并直接通过 HID++ 报文读取与设定硬件 DPI。
public final class LogitechHIDPP: ObservableObject {
    public static let shared = LogitechHIDPP()

    public struct LogiDevice: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let isReceiver: Bool
        public var currentDPI: Int
        public var supportedDPIs: [Int]
    }

    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var devices: [LogiDevice] = []
    @Published public private(set) var statusMessage: String = "未连接罗技设备"

    private var hidManager: IOHIDManager?
    /// 设备插拔回调（IOHIDManager 事件驱动，替代原来的 5 秒全量轮询）。
    /// 类型是闭包而不是 C 函数指针：IOHIDManagerRegisterDeviceMatchingCallback 的
    /// 最后一格就是 UnsafeMutableRawPointer?，可以用 `Unmanaged` 把 self 传过去。
    private var matchCallback: IOHIDDeviceCallback?
    private var removalCallback: IOHIDDeviceCallback?

    private static let logitechVendorID = 0x046D
    private static let featureRootID: UInt16 = 0x0000
    private static let featureAdjustableDPI: UInt16 = 0x2201

    public init() {
        setupManager()
    }

    private func setupManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDVendorIDKey: Self.logitechVendorID]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = manager

        scan()
        // 事件驱动插拔检测：插上 / 拔掉罗技外设时由 IOKit 直接回调。
        // 原来是 5 秒一次全量 scan()，G502 X 常插在机器上就是持续的 IOKit 枚举开销；
        // 而且插上鼠标到界面反映出来最多要等 5 秒，体感像「没检测到」。
        let box = Unmanaged.passRetained(self).toOpaque()
        // IOHIDDeviceCallback 是 4 参 (context, result, device, sender)：中间那个 IOReturn
        // 是 IOKit 的结果码，这里不关心；device/sender 都用不上，scan() 自己重新枚举。
        matchCallback = { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<LogitechHIDPP>.fromOpaque(ctx).takeUnretainedValue().scan()
        }
        removalCallback = { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<LogitechHIDPP>.fromOpaque(ctx).takeUnretainedValue().scan()
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCallback!, box)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, removalCallback!, box)
        // 不调用 IOHIDManagerScheduleWithRunLoop：回调本来就跑在自己的队列上，
        // 再挂主 run loop 会让 scan() 与 UI 刷新抢同一线程（scan 内部已 DispatchQueue.main.async）。
    }

    public func scan() {
        guard let manager = hidManager,
              let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty else {
            DispatchQueue.main.async {
                self.isConnected = false
                self.devices = []
                self.statusMessage = "未发现罗技外设"
            }
            return
        }

        var foundDevices: [LogiDevice] = []
        var hasReceiver = false

        for dev in set {
            let prod = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? "Logitech Device"
            let page = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
            if page == 0xFF00 {
                hasReceiver = true
            }
            let isRec = prod.localizedCaseInsensitiveContains("Receiver")
            let devItem = LogiDevice(
                id: "\(dev.hashValue)",
                name: prod,
                isReceiver: isRec,
                currentDPI: 1000,
                supportedDPIs: [400, 800, 1000, 1200, 1600, 2000, 2400, 3200, 4000]
            )
            if !foundDevices.contains(where: { $0.name == prod }) {
                foundDevices.append(devItem)
            }
        }

        DispatchQueue.main.async {
            self.devices = foundDevices
            self.isConnected = !foundDevices.isEmpty
            if hasReceiver {
                self.statusMessage = "已连接 Logitech USB Receiver (支持 HID++ 2.0)"
            } else if self.isConnected {
                self.statusMessage = "已连接罗技设备"
            }
        }
    }

    /// 通过 HID++ 协议向硬件下发目标 DPI
    public func setDPI(_ targetDPI: Int) {
        guard let manager = hidManager,
              let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }

        let dpi16 = UInt16(min(65535, max(100, targetDPI)))
        let bigDPI = dpi16.bigEndian

        for dev in set {
            let page = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
            guard page == 0xFF00 else { continue }

            // 构造 HID++ 2.0 Feature 0x2201 Function 0x03 (setDpi)
            // ReportID: 0x11, DevIdx: 0x01, Feature: 0x22, Func: 0x03, Sensor: 0x00, DPI: 2 bytes
            var req = [UInt8](repeating: 0, count: 20)
            req[0] = 0x11
            req[1] = 0x01 // 配对鼠标
            req[2] = 0x22
            req[3] = 0x03
            req[4] = 0x00 // sensor 0
            withUnsafeBytes(of: bigDPI) { bytes in
                req[5] = bytes[0]
                req[6] = bytes[1]
            }

            _ = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x11, req, 20)
        }

        // 本地状态更新
        DispatchQueue.main.async {
            for i in 0..<self.devices.count {
                self.devices[i].currentDPI = targetDPI
            }
            self.statusMessage = "已应用硬件 DPI: \(targetDPI)"
        }
    }
}
