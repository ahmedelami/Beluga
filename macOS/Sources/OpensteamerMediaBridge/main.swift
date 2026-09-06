import Darwin
import Foundation
import MediaBridgeCore

// Chrome owns this process. It can forward bounded media messages only to the
// current user's host socket; it never starts CaptureServer or evaluates commands.
guard CommandLine.arguments.count == 2,
      CommandLine.arguments[1] == MediaBridgeProtocol.origin else { exit(64) }
signal(SIGPIPE, SIG_IGN)
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
