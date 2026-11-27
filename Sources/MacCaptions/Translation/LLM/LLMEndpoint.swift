import Foundation

// MARK: - Server address

enum EndpointScope: Equatable {
    case thisMac, localNetwork, internet
}

struct LLMEndpoint: Equatable {
    let base: URL
    let scope: EndpointScope
    var host: String { base.host ?? "" }
    var hostAndPort: String { base.port.map { "\(host):\($0)" } ?? host }
    /// Scheme, host and port: the unit an API key belongs to.
    var origin: String { "\(base.scheme?.lowercased() ?? "https")://\(hostAndPort.lowercased())" }
    var chatURL: URL { base.appendingPathComponent("chat/completions") }
    var modelsURL: URL { base.appendingPathComponent("models") }

    /// Where the caption text goes, in words, for the UI.
    var destination: String {
        switch scope {
        case .thisMac: "this Mac"
        case .localNetwork: "your network (\(hostAndPort))"
        case .internet: "the internet (\(hostAndPort))"
        }
    }

    struct Invalid: Error, CustomStringConvertible { let description: String }

    /// Cleans up what the user typed. Plain http is only allowed to this Mac or the local network, so neither the
    /// API key nor the transcript ever crosses the internet unencrypted.
    static func parse(_ raw: String) throws -> LLMEndpoint {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw Invalid(description: "Enter the server address.") }
        if !s.contains("://") {
            let probe = URL(string: "http://" + s)?.host ?? ""
            s = (scope(ofHost: probe) == .internet ? "https://" : "http://") + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        // People often paste the full endpoint; accept that too.
        if s.hasSuffix("/chat/completions") { s.removeLast("/chat/completions".count) }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { throw Invalid(description: "That is not a valid http(s) address.") }
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw Invalid(description: "The address must not contain a user name, password or “?” part. Put the key in the API key field.")
        }
        let where_ = scope(ofHost: host)
        if scheme == "http" && where_ == .internet {
            throw Invalid(description: "Use https for servers on the internet. Plain http is only allowed on this Mac or your local network.")
        }
        return LLMEndpoint(base: url, scope: where_)
    }

    static func scope(ofHost rawHost: String) -> EndpointScope {
        let h = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h == "::1" { return .thisMac }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { UInt8($0) }
        // Leading zeros make some resolvers read a number as octal ("010" = 8), so such addresses are not trusted.
        if parts.count == 4 && numbers.count == 4 && !parts.contains(where: { $0.count > 1 && $0.hasPrefix("0") }) {
            if numbers[0] == 127 || numbers == [0, 0, 0, 0] { return .thisMac }
            if numbers[0] == 10 || (numbers[0] == 192 && numbers[1] == 168) || (numbers[0] == 169 && numbers[1] == 254)
                || (numbers[0] == 172 && (16...31).contains(numbers[1])) { return .localNetwork }
            return .internet
        }
        if h.contains(":") {                                            // IPv6 literal
            return h.hasPrefix("fe80:") || h.hasPrefix("fd") || h.hasPrefix("fc") ? .localNetwork : .internet
        }
        // Names must be plain ASCII: look-alike characters such as "。" can turn into real dots on the way out.
        func isPlainLabel(_ s: Substring) -> Bool { !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }
        if h.hasSuffix(".local") && parts.allSatisfy(isPlainLabel) { return .localNetwork }
        // A bare name like "studio" can only be a machine on the local network. All-digit forms such as
        // "2130706433" are numeric addresses in disguise, so they are not trusted.
        if parts.count == 1 && isPlainLabel(parts[0]) && h.contains(where: { $0.isLetter }) && !h.hasPrefix("0x") { return .localNetwork }
        return .internet
    }
}
