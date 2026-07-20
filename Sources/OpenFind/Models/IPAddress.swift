import Darwin
import Foundation

struct IPAddress: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    enum Family: Int, Codable, Sendable {
        case v4 = 4
        case v6 = 6
    }

    let family: Family
    private let bytes: [UInt8]

    init?(_ value: String) {
        let address = value.split(separator: "%", maxSplits: 1).first.map(String.init) ?? value
        guard !address.isEmpty, address.utf8.count <= 64 else { return nil }

        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            family = .v4
            bytes = withUnsafeBytes(of: &ipv4) { Array($0) }
            return
        }

        var ipv6 = in6_addr()
        if address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            family = .v6
            bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            return
        }
        return nil
    }

    var description: String {
        var storage = bytes
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let addressFamily = family == .v4 ? AF_INET : AF_INET6
        let converted = storage.withUnsafeMutableBytes { buffer in
            inet_ntop(addressFamily, buffer.baseAddress, &output, socklen_t(output.count))
        }
        guard converted != nil else { return "" }
        let bytes = output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func < (lhs: IPAddress, rhs: IPAddress) -> Bool {
        if lhs.family != rhs.family { return lhs.family.rawValue < rhs.family.rawValue }
        return lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let address = IPAddress(value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid IP address"
            )
        }
        self = address
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
