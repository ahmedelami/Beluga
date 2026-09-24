import CryptoKit
import Foundation

/// Shared wire-format contract for the screen challenge, screenshot matcher, and physical runner.
/// Keeping the payload constructor here prevents a challenge/decoder protocol split.
enum PhysicalScreenSequenceProtocol {
    static let symbolCount = 4
    static let gridCount = 4
    static let minimumFrameDimension = 20
    static let minimumGridDimension = 20
    static let minimumGridPercent = 35
    static let maximumGridPercent = 90

    static func isValidNonce(_ nonce: String) -> Bool {
        nonce.utf8.count == 32 && nonce.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    /// Two index bits followed by the first ten SHA-256 bits of the versioned message. Binding the
    /// index in-band makes all four symbols collision-free while retaining nonce unpredictability.
    static func payload(nonce: String, index: Int) -> UInt16 {
        precondition((0..<symbolCount).contains(index))
        let message = "opensteamer-screen-oracle-v1:\(nonce):\(index)"
        let digest = Array(SHA256.hash(data: Data(message.utf8)))
        let nonceBits = (UInt16(digest[0]) << 2) | (UInt16(digest[1]) >> 6)
        return (UInt16(index) << 10) | nonceBits
    }
}
