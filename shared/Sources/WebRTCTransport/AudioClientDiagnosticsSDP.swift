import Foundation

enum AudioClientDiagnosticsSDP {
    static let attributeName = "x-opensteamer-audio-client-diagnostics"
    static let prefix = "a=\(attributeName):"

    static func authorization(in sdp: String) -> UUID? {
        let lines = sdp.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let session = lines.prefix { !$0.hasPrefix("m=") }
        let attributes = session.filter { $0.hasPrefix(prefix) }
        guard attributes.count == 1 else { return nil }
        let parts = attributes[0].dropFirst(prefix.count).split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "1",
              let id = UUID(uuidString: String(parts[1])) else { return nil }
        return id
    }

    static func negotiatedAuthorization(hostOfferSDP: String, viewerAnswerSDP: String) -> UUID? {
        guard let offer = authorization(in: hostOfferSDP),
              authorization(in: viewerAnswerSDP) == offer else { return nil }
        return offer
    }

    static func advertisingHostSupport(in sdp: String, authorization: UUID) -> String {
        insert(in: sdp, authorization: authorization)
    }

    static func advertisingViewerSupport(in sdp: String, remoteOfferSDP: String) -> String {
        guard let authorization = authorization(in: remoteOfferSDP) else { return sdp }
        return insert(in: sdp, authorization: authorization)
    }

    private static func insert(in sdp: String, authorization: UUID) -> String {
        let separator = sdp.contains("\r\n") ? "\r\n" : "\n"
        var lines = sdp.components(separatedBy: separator)
        let position = lines.firstIndex { $0.hasPrefix("m=") } ?? lines.endIndex
        guard !lines[..<position].contains(where: { $0.hasPrefix(prefix) }) else { return sdp }
        lines.insert("\(prefix)1 \(authorization.uuidString)", at: position)
        return lines.joined(separator: separator)
    }
}
