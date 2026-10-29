// Diagnostic-only script for azooKey-Desktop issue #348.
// Reads the WindowServer window list without changing any application state.
// Usage: swift Tools/window-lifecycle-snapshot.swift <azooKeyMac PID> [--ids]

import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard (arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--ids")),
      let pid = Int32(arguments[1]),
      pid > 0 else {
    fputs("Usage: swift Tools/window-lifecycle-snapshot.swift <pid> [--ids]\n", stderr)
    exit(EXIT_FAILURE)
}

struct WindowGroup: Hashable {
    let width: Int
    let height: Int
    let layer: Int
    let onscreen: Bool

    var description: String {
        "\(width)x\(height) layer=\(layer) onscreen=\(onscreen)"
    }
}

let windows = (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]) ?? []
let ownedWindows = windows.filter {
    ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
}
let groups = Dictionary(grouping: ownedWindows) { window in
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    return WindowGroup(
        width: (bounds["Width"] as? NSNumber)?.intValue ?? -1,
        height: (bounds["Height"] as? NSNumber)?.intValue ?? -1,
        layer: (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
        onscreen: (window[kCGWindowIsOnscreen as String] as? Bool) ?? false
    )
}

print("time=\(ISO8601DateFormatter().string(from: Date())) pid=\(pid) windows=\(ownedWindows.count)")
for (group, windows) in groups.sorted(by: {
    if $0.value.count != $1.value.count {
        return $0.value.count > $1.value.count
    }
    return $0.key.description < $1.key.description
}) {
    print("\(windows.count) \(group.description)")
    if arguments.count == 3 {
        let ids = windows.compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.intValue
        }.sorted()
        print("  windowIDs: \(ids.map(String.init).joined(separator: ", "))")
    }
}
