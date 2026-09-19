import Darwin
import Foundation
import MediaBridgeCore

guard CommandLine.arguments.count == 2 else { exit(64) }
let argument = CommandLine.arguments[1]
let onboardingType = MediaAutomationOnboarding.requestType(argument: argument)
guard argument == MediaBridgeProtocol.origin || onboardingType != nil else { exit(64) }
signal(SIGPIPE, SIG_IGN)
if let onboardingType {
    do {
        let fd = try MediaBridgeSocket.connect()
        defer { close(fd) }
        let id = UUID().uuidString
        try MediaBridgeFraming.writeFrame(fd, data: MediaAutomationOnboarding.request(type: onboardingType, id: id))
        guard let reply = try MediaBridgeFraming.readFrame(fd, idleTimeout: 35) else { throw MediaBridgeError.closed }
        let result = try MediaAutomationOnboarding.result(reply, expectedID: id)
        print("\(onboardingType): \(result)")
        exit(result == "authorized" ? 0 : 1)
    } catch {
        fputs("Media automation onboarding unavailable; keep the signed opensteamer host running.\n", stderr)
        exit(1)
    }
}
// Compatibility mode forwards only bounded typed messages from the exact native
// messaging origin. Neither mode launches the host or evaluates arbitrary code.
let outputFlags = fcntl(STDOUT_FILENO, F_GETFL)
guard outputFlags >= 0, fcntl(STDOUT_FILENO, F_SETFL, outputFlags | O_NONBLOCK) == 0 else { exit(1) }
do {
    let fd = try MediaBridgeSocket.connect()
    DispatchQueue.global(qos: .utility).async {
        do {
            while let data = try MediaBridgeFraming.readFrame(STDIN_FILENO) {
                _ = try MediaBridgeProtocol.decode(data)
                try MediaBridgeFraming.writeFrame(fd, data: data)
            }
        } catch { /* A closed/invalid browser stream retires this authority. */ }
        _ = shutdown(fd, SHUT_RDWR)
    }
    defer { close(fd) }
    while let data = try MediaBridgeFraming.readFrame(fd) {
        try MediaBridgeFraming.writeFrame(STDOUT_FILENO, data: data)
    }
} catch {
    // No metadata or payloads on stderr, and never non-framed stdout.
    fputs("Opensteamer media bridge unavailable\n", stderr)
    exit(1)
}
