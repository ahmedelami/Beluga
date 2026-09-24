import CoreAudio
import Foundation

private enum MonitorFailure: Error {
    case usage
    case coreAudio(String, OSStatus)
    case wrongRoute(String)
    case listenerTeardown
}

private final class StickyNotifications: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let handle: FileHandle

    init(path: String) throws {
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
    }

    func record(_ addresses: UnsafePointer<AudioObjectPropertyAddress>, count addressCount: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        count += Int(addressCount)
        for index in 0..<Int(addressCount) {
            let line = "selector=\(addresses[index].mSelector)\n"
            if let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
        try? handle.synchronize()
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func close() throws {
        try handle.synchronize()
        try handle.close()
    }
}

private func readAudioDeviceID(
    _ object: AudioObjectID,
    _ address: inout AudioObjectPropertyAddress
) throws -> AudioDeviceID {
    var value = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    guard status == noErr, size == UInt32(MemoryLayout<AudioDeviceID>.size) else {
        throw MonitorFailure.coreAudio("read scalar", status)
    }
    return value
}

private func defaultUID(_ selector: AudioObjectPropertySelector) throws -> String {
    var defaultAddress = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let device = try readAudioDeviceID(AudioObjectID(kAudioObjectSystemObject), &defaultAddress)
    var uidAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &size, pointer)
    }
    guard status == noErr, size == UInt32(MemoryLayout<CFString>.size) else {
        throw MonitorFailure.coreAudio("read device UID", status)
    }
    return value as String
}

private struct Snapshot: Equatable {
    let input: String
    let output: String
    let system: String
}

private func snapshot() throws -> Snapshot {
    Snapshot(
        input: try defaultUID(kAudioHardwarePropertyDefaultInputDevice),
        output: try defaultUID(kAudioHardwarePropertyDefaultOutputDevice),
        system: try defaultUID(kAudioHardwarePropertyDefaultSystemOutputDevice)
    )
}

private func main() throws {
    guard CommandLine.arguments.count == 5 else { throw MonitorFailure.usage }
    let eventPath = CommandLine.arguments[1]
    let expected = Snapshot(
        input: CommandLine.arguments[2],
        output: CommandLine.arguments[3],
        system: CommandLine.arguments[4]
    )
    let notifications = try StickyNotifications(path: eventPath)
    let queue = DispatchQueue(label: "opensteamer.v90.sticky-coreaudio-route-monitor")
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    let selectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice,
    ]
    let block: AudioObjectPropertyListenerBlock = { count, addresses in
        notifications.record(addresses, count: count)
    }
    var installed: [AudioObjectPropertyAddress] = []
    defer {
        for stored in installed.reversed() {
            var address = stored
            _ = AudioObjectRemovePropertyListenerBlock(systemObject, &address, queue, block)
        }
        queue.sync {}
    }

    let before = try snapshot()
    guard before == expected else { throw MonitorFailure.wrongRoute("initial") }
    for selector in selectors {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(systemObject, &address, queue, block)
        guard status == noErr else {
            throw MonitorFailure.coreAudio("install listener", status)
        }
        installed.append(address)
    }
    let armed = try snapshot()
    guard armed == expected else { throw MonitorFailure.wrongRoute("armed") }
    print("READY input=\(armed.input) output=\(armed.output) system=\(armed.system)")
    fflush(stdout)

    guard readLine() == "STOP" else { throw MonitorFailure.usage }
    let final = try snapshot()
    var teardownOK = true
    for stored in installed.reversed() {
        var address = stored
        if AudioObjectRemovePropertyListenerBlock(systemObject, &address, queue, block) != noErr {
            teardownOK = false
        }
    }
    installed.removeAll()
    queue.sync {}
    let count = notifications.snapshot()
    try notifications.close()
    print(
        "RESULT notifications=\(count) teardown=\(teardownOK ? "clean" : "failed") "
            + "input=\(final.input) output=\(final.output) system=\(final.system)"
    )
    fflush(stdout)
    guard teardownOK else { throw MonitorFailure.listenerTeardown }
    guard count == 0 else { throw MonitorFailure.wrongRoute("notification") }
    guard final == expected else { throw MonitorFailure.wrongRoute("final") }
}

do {
    try main()
} catch {
    fputs("opensteamer-v90-coreaudio-route-monitor: \(error)\n", stderr)
    exit(1)
}
