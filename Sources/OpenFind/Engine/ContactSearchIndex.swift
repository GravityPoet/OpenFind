@preconcurrency import Contacts
import Foundation

struct QuickContact: Hashable, Sendable {
    let identifier: String
    let name: String
    let emails: [String]
    let phones: [String]
    let aliases: [String]

    let candidate: ApplicationSearchResult

    init(identifier: String, name: String, emails: [String], phones: [String], aliases: [String]) {
        self.identifier = identifier
        self.name = name
        self.emails = emails
        self.phones = phones
        self.aliases = aliases
        var components = URLComponents()
        components.scheme = "openfind-contact"
        components.path = "/" + identifier
        candidate = .init(url: components.url!, name: name, bundleIdentifier: nil, aliases: aliases + emails + phones)
    }
}

enum ContactSearchIndex {
    static var isAuthorized: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }

    /// Checking authorization is non-blocking. Permission is requested only
    /// when the user activates the dedicated access row, never while typing.
    static func accessResponse() -> QuickSearchSourceResponse {
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            return .init(items: [.init(url: URL(string: "openfind-action:/contacts-access")!,
                name: L("Allow Contacts Access"), location: L("Contacts Access Help"), kind: .command,
                action: .requestContactsAccess)])
        }
        return .init(items: [.init(url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!,
            name: L("Allow Contacts Access"), location: L("Contacts Access Help"), kind: .command)])
    }

    static func requestAccess() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    static func discover() throws -> [QuickContact] {
        guard isAuthorized else { return [] }
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactNicknameKey as NSString, CNContactEmailAddressesKey as NSString, CNContactPhoneNumbersKey as NSString]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        var contacts: [QuickContact] = []
        try CNContactStore().enumerateContacts(with: request) { contact, stop in
            if Task.isCancelled { stop.pointee = true; return }
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? L("Unnamed Contact")
            contacts.append(.init(identifier: contact.identifier, name: name,
                emails: contact.emailAddresses.map { $0.value as String },
                phones: contact.phoneNumbers.map { $0.value.stringValue },
                aliases: [contact.nickname, contact.givenName + contact.familyName, contact.familyName + contact.givenName]))
        }
        return contacts
    }

    static func search(_ query: String, contacts: [QuickContact], limit: Int) -> QuickSearchSourceResponse {
        let candidates = contacts.map(\.candidate)
        let matched = query.isEmpty ? candidates : ApplicationSearchMatcher.rank(query, in: candidates)
        let byID = Dictionary(zip(candidates.map(\.url), contacts), uniquingKeysWith: { first, _ in first })
        return .page(matched.compactMap { candidate in
            guard let contact = byID[candidate.url] else { return nil }
            return .init(url: candidate.url, name: candidate.name, location: L("Contacts"),
                         kind: .contact, action: .showContact(contact))
        }, limit: limit)
    }
}
