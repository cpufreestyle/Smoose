import Foundation
import IOKit
import IOKit.hidsystem

let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { exit(1) }

for s in services {
    guard IOHIDServiceClientConformsTo(s, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0 else { continue }
    guard let transport = IOHIDServiceClientCopyProperty(s, "Transport" as CFString) as? String, transport != "FIFO" else { continue }
    let name = IOHIDServiceClientCopyProperty(s, "Product" as CFString).map { "\($0)" } ?? "?"
    let key = (IOHIDServiceClientCopyProperty(s, "HIDPointerAccelerationType" as CFString) as? String) ?? "HIDMouseAcceleration"
    let original = (IOHIDServiceClientCopyProperty(s, key as CFString) as? NSNumber)?.doubleValue ?? -1
    print("── \(name) key=\(key) 原始=\(original)")

    for trial in [0, 163840, 65536] {
        let ok = IOHIDServiceClientSetProperty(s, key as CFString, NSNumber(value: trial))
        let back = (IOHIDServiceClientCopyProperty(s, key as CFString) as? NSNumber)?.doubleValue ?? -1
        print(String(format: "   set %8d -> ok=%@ readBack=%8.0f", trial, ok ? "true" : "false", back))
    }

    // 还原
    IOHIDServiceClientSetProperty(s, key as CFString, NSNumber(value: Int(original)))
    let restored = (IOHIDServiceClientCopyProperty(s, key as CFString) as? NSNumber)?.doubleValue ?? -1
    print("   还原 -> \(restored)")
}
