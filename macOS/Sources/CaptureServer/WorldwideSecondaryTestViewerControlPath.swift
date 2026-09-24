import Darwin
import Foundation

/// Path spelling must not change when an output or socket is created. Foundation
/// standardization can collapse /private/tmp to /tmp only after the leaf exists.
enum WorldwideSecondaryTestViewerControlPath {
    static func isLexicallyAbsolute(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path != "/" else { return false }
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Resolve existing directories with POSIX semantics, without Foundation's
    /// presentation aliases. Only the standard macOS system aliases are allowed;
    /// an arbitrary symlink anywhere in the directory chain remains invalid.
    static func isCanonicalDirectory(_ path: String) -> Bool {
        guard path == "/" || isLexicallyAbsolute(path),
              let resolved = realpath(path, nil) else { return false }
        defer { free(resolved) }
        let actual = String(cString: resolved)
        if actual == path { return true }
        for alias in ["/tmp", "/var", "/etc"] {
            if path == alias || path.hasPrefix(alias + "/") {
                return actual == "/private" + path
            }
        }
        return false
    }

    static func hasCanonicalParent(_ path: String) -> Bool {
        guard isLexicallyAbsolute(path), let separator = path.lastIndex(of: "/") else {
            return false
        }
        let parent = separator == path.startIndex ? "/" : String(path[..<separator])
        return isCanonicalDirectory(parent)
    }
}
