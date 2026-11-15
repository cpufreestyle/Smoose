import Foundation
import IOKit
import IOKit.hid

// 只读探针：只枚举 0x046D 设备的属性，不 IOHIDDeviceOpen、
// 不 SetReport、不注册回调、不改任何设备状态。
//
// 用途：排查「罗技接收器是否被别的 HID++ 客户端占用 / 有几个 0xFF00 控制接口」。
// 编译（受限环境要 -disable-sandbox，否则 IORegistry 读到空）：
//   SDK="$(xcrun --sdk macosx --show-sdk-path)"
//   SWIFTC="$(xcrun --sdk macosx --find swiftc)"
//   "$SWIFTC" -disable-sandbox -Onone -sdk "$SDK" -target arm64-apple-macos14.0 \
//     -o /tmp/smoose_hidpp_readonly Probe/HIDPPReadOnlyProbe.swift
//   /tmp/smoose_hidpp_readonly
//
// 2026-11-12 实测：两个接收器 0xc547 / 0xc548，各带一个 0xFF00 接口；
// 项目源码记录 0xc547 支持 0x2201（featureIndex=7），0xc548 明确不支持。
// 注意 macOS 的 IOKit 允许多个 client 打开同一 HID 设备，不像 Windows 的
// Bolt/Unifying 接收器那样「一次只允许一个应用持有 HID++」；但同一条 0xFF00
// 通道上多进程并发下发 HID++ 请求仍会串扰，所以竞争进程依然要查。

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)
let rc = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("IOHIDManagerOpen rc=\(rc)")

guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
    print("RESULT: no Logitech HID devices visible")
    exit(2)
}

struct Row { let pid: Int; let page: Int; let name: String; let transport: String }
var rows: [Row] = []
for dev in set {
    let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? -1
    let page = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? -1
    let name = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? "?"
    let transport = (IOHIDDeviceGetProperty(dev, kIOHIDTransportKey as CFString) as? String) ?? "?"
    rows.append(Row(pid: pid, page: page, name: name, transport: transport))
}
rows.sort { $0.pid == $1.pid ? $0.page < $1.page : $0.pid < $1.pid }
print("RESULT: \(rows.count) Logitech HID interfaces")
for r in rows {
    let flag = r.page == 0xFF00 ? "   <-- HID++ control (Smoose matches this)" : ""
    print(String(format: "  PID=0x%04x page=0x%04x transport=%-12@ name=%@%@",
                 r.pid, r.page, r.transport, r.name, flag))
}
let control = rows.filter { $0.page == 0xFF00 }
print("CONTROL_INTERFACES=\(control.count)")
print("CONTROL_PIDS=" + control.map { String(format: "0x%04x", $0.pid) }.joined(separator: ","))
