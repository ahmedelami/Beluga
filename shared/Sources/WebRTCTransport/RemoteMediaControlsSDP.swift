import Foundation

/// Echoed opt-in for Mac Now Playing metadata and commands on the strict ordered control lane.
/// Without the exact version and authorization echo, neither side may send a media message.
enum RemoteMediaControlsSDP {
    static let currentProtocolVersion = 1
    static let attributeName = "x-opensteamer-remote-media-controls"
    private static let attributePrefix = "a=\(attributeName):"

    static func attributeLine(
        for authorization: WebRTCRemoteMediaAuthorization
    ) -> String {
        attributePrefix
            + "\(currentProtocolVersion):"
            + authorization.id.uuidString.lowercased()
    }

    static func advertisingHostSupport(
        in sessionDescription: String,
        authorization: WebRTCRemoteMediaAuthorization
    ) -> String {
        insertingCapabilityIfNeeded(
            in: sessionDescription,
            authorization: authorization
        )
    }

    static func advertisingViewerSupport(
        in sessionDescription: String,
        remoteOfferSDP: String
    ) -> String {
        guard let authorization = advertisedAuthorization(in: remoteOfferSDP) else {
            return sessionDescription
        }
        return insertingCapabilityIfNeeded(
            in: sessionDescription,
            authorization: authorization
        )
    }

    static func negotiatedAuthorization(
        hostOfferSDP: String,
        viewerAnswerSDP: String
    ) -> WebRTCRemoteMediaAuthorization? {
        guard let offered = advertisedAuthorization(in: hostOfferSDP),
              let answered = advertisedAuthorization(in: viewerAnswerSDP),
              offered == answered else {
            return nil
        }
        return offered
    }

    static func peerSupportsControls(in sessionDescription: String) -> Bool {
        advertisedAuthorization(in: sessionDescription) != nil
    }

    static func advertisedAuthorization(
        in sessionDescription: String
    ) -> WebRTCRemoteMediaAuthorization? {
        let separator = sessionDescription.contains("\r\n") ? "\r\n" : "\n"
        var matchingValue: String?
        for line in sessionDescription.components(separatedBy: separator) {
            if line.hasPrefix("m=") { break }
            guard line.hasPrefix(attributePrefix) else { continue }
            // Multiple declarations, including mixed protocol versions, are ambiguous and fail
            // closed instead of allowing an attacker-controlled downgrade or token selection.
            guard matchingValue == nil else { return nil }
            matchingValue = String(line.dropFirst(attributePrefix.count))
        }
        guard let matchingValue else { return nil }
        let components = matchingValue.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              components[0] == Substring(String(currentProtocolVersion)) else {
            return nil
        }
        let rawID = String(components[1])
        guard rawID.count == 36,
              rawID == rawID.lowercased(),
              let id = UUID(uuidString: rawID),
              id.uuidString.lowercased() == rawID else {
            return nil
        }
        return WebRTCRemoteMediaAuthorization(id: id)
    }

    private static func insertingCapabilityIfNeeded(
        in sessionDescription: String,
        authorization: WebRTCRemoteMediaAuthorization
    ) -> String {
        let expectedLine = attributeLine(for: authorization)
        if advertisedAuthorization(in: sessionDescription) == authorization {
            return sessionDescription
        }
        let separator = sessionDescription.contains("\r\n") ? "\r\n" : "\n"
        let preservesTrailingSeparator = sessionDescription.hasSuffix(separator)
        var lines = sessionDescription.components(separatedBy: separator)
        if preservesTrailingSeparator, lines.last == "" { lines.removeLast() }
        let insertionIndex = lines.firstIndex(where: { $0.hasPrefix("m=") })
            ?? lines.endIndex
        lines.insert(expectedLine, at: insertionIndex)
        let result = lines.joined(separator: separator)
        return preservesTrailingSeparator ? result + separator : result
    }
}
