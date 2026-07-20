import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

struct NetworkTriggerSignals {
    let wifiSSID: String?
    let ipAddresses: Set<IPAddress>
    let dnsServers: Set<IPAddress>
    let activeVPNServices: Set<String>

    static func current(needsWiFi: Bool, needsNetwork: Bool) -> Self {
        guard needsNetwork || needsWiFi else {
            return Self(wifiSSID: nil, ipAddresses: [], dnsServers: [], activeVPNServices: [])
        }
        return Self(
            wifiSSID: needsWiFi ? CWWiFiClient.shared().interface()?.ssid() : nil,
            ipAddresses: needsNetwork ? addresses() : [],
            dnsServers: needsNetwork ? dnsAddresses() : [],
            activeVPNServices: needsNetwork ? activeVPNs() : []
        )
    }

    private static func addresses() -> Set<IPAddress> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { if let head { freeifaddrs(head) } }

        var addresses: Set<IPAddress> = []
        var cursor = head
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = current.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = current.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            let length: socklen_t = family == AF_INET
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                address,
                length,
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { continue }
            let value = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
            if let parsed = IPAddress(value) { addresses.insert(parsed) }
        }
        return addresses
    }

    private static func dnsAddresses() -> Set<IPAddress> {
        guard let store = SCDynamicStoreCreate(nil, "OpenFind" as NSString, nil, nil) else {
            return []
        }
        var values: [[String: Any]] = []
        if let global = SCDynamicStoreCopyValue(
            store,
            "State:/Network/Global/DNS" as NSString
        ) as? [String: Any] {
            values.append(global)
        }
        let serviceKeys = SCDynamicStoreCopyKeyList(
            store,
            "State:/Network/Service/[^/]+/DNS" as NSString
        ) as? [String] ?? []
        values.append(contentsOf: serviceKeys.compactMap {
            SCDynamicStoreCopyValue(store, $0 as NSString) as? [String: Any]
        })
        return parsedDNSAddresses(from: values)
    }

    private static func activeVPNs() -> Set<String> {
        activeConfiguredVPNs().union(activeDynamicStoreVPNs())
    }

    static func parsedDNSAddresses(from values: [[String: Any]]) -> Set<IPAddress> {
        Set(values.flatMap { ($0["ServerAddresses"] as? [String]) ?? [] }.compactMap(IPAddress.init))
    }

    private static func activeConfiguredVPNs() -> Set<String> {
        guard let preferences = SCPreferencesCreate(
            nil,
            "OpenFind.TriggerSignals" as CFString,
            nil
        ), let networkSet = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(networkSet) else { return [] }

        var names: Set<String> = []
        for case let service as SCNetworkService in services as NSArray {
            guard let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface).map({ $0 as String }),
                  ["VPN", "PPP", "IPSec", "L2TP", "PPTP"].contains(type),
                  let serviceID = SCNetworkServiceGetServiceID(service),
                  let connection = SCNetworkConnectionCreateWithServiceID(
                      nil,
                      serviceID,
                      nil,
                      nil
                  ),
                  SCNetworkConnectionGetStatus(connection) == .connected else { continue }
            let name = SCNetworkServiceGetName(service).map { $0 as String }
                ?? (serviceID as String)
            if !name.isEmpty { names.insert(name) }
        }
        return names
    }

    private static func activeDynamicStoreVPNs() -> Set<String> {
        guard let store = SCDynamicStoreCreate(nil, "OpenFind" as NSString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(
                  store,
                  "State:/Network/Service/[^/]+/(IPv4|IPv6)" as NSString
              ) as? [String] else { return [] }
        var names: Set<String> = []
        for key in keys {
            guard let state = SCDynamicStoreCopyValue(store, key as NSString) as? [String: Any],
                  isDynamicVPNState(state) else { continue }
            let parts = key.split(separator: "/")
            guard let serviceID = parts.dropFirst(3).first else { continue }
            let setupKey = "Setup:/Network/Service/\(serviceID)"
            let setup = SCDynamicStoreCopyValue(store, setupKey as NSString) as? [String: Any]
            let name = setup?["UserDefinedName"] as? String ?? String(serviceID)
            names.insert(name)
        }
        return names
    }

    static func isDynamicVPNState(_ state: [String: Any]) -> Bool {
        let interface = state["Interface"] as? [String: Any] ?? [:]
        let values = [
            state["InterfaceName"] as? String,
            state["ConfirmedInterfaceName"] as? String,
            interface["DeviceName"] as? String,
            interface["Type"] as? String,
            interface["SubType"] as? String,
            interface["Hardware"] as? String,
        ]
        .compactMap { $0?.lowercased() }
        return values.contains { value in
            value.hasPrefix("utun")
                || value.hasPrefix("ppp")
                || value.contains("vpn")
                || value.contains("ipsec")
                || value.contains("l2tp")
                || value.contains("pptp")
        }
    }
}
