import Foundation

struct SearchQueryPlan: Sendable, Equatable {
    var plainTerms: [String] = []
    var explicitContentTerms: [String] = []
    var excludedTerms: [String] = []
    var filters: [SearchQueryFilter] = []
    var excludedFilters: [SearchQueryFilter] = []

    static func parse(_ query: String) -> SearchQueryPlan {
        var plan = SearchQueryPlan()
        for rawToken in tokenize(query) {
            var token = rawToken
            let negated = token.hasPrefix("!")
            if negated {
                token.removeFirst()
            }
            guard !token.isEmpty else { continue }

            if let clause = parseClause(token) {
                switch (negated, clause) {
                case (false, .plain(let value)):
                    plan.plainTerms.append(value)
                case (true, .plain(let value)):
                    plan.excludedTerms.append(value)
                case (false, .content(let value)):
                    plan.explicitContentTerms.append(value)
                case (true, .content(let value)):
                    plan.excludedTerms.append(value)
                case (false, .filter(let filter)):
                    plan.filters.append(filter)
                case (true, .filter(let filter)):
                    plan.excludedFilters.append(filter)
                }
            } else if negated {
                plan.excludedTerms.append(token)
            } else {
                plan.plainTerms.append(token)
            }
        }
        return plan
    }

    func compile(options: SearchOptions) throws -> CompiledSearchQuery {
        let plainMatchers = try plainTerms.map { try makeMatcher(term: $0, options: options) }
        let contentMatchers = try explicitContentTerms.map { try makeMatcher(term: $0, options: options) }
        let excludedMatchers = try excludedTerms.map { try makeMatcher(term: $0, options: options) }
        return CompiledSearchQuery(
            plan: self,
            plainMatchers: plainMatchers,
            explicitContentMatchers: contentMatchers,
            excludedMatchers: excludedMatchers
        )
    }

    private static func parseClause(_ token: String) -> SearchQueryClause? {
        guard let separator = token.firstIndex(of: ":") else {
            return .plain(token)
        }

        let key = token[..<separator].lowercased()
        let value = String(token[token.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)

        switch key {
        case "ext", "extension":
            guard !value.isEmpty else { return nil }
            return .filter(.extensionIs(value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()))

        case "file":
            if value.isEmpty { return .filter(.kind(.file)) }
            return .filter(.kindAndName(.file, value))

        case "folder", "dir":
            if value.isEmpty { return .filter(.kind(.folder)) }
            return .filter(.kindAndName(.folder, value))

        case "path":
            guard !value.isEmpty else { return nil }
            return .filter(.pathContains(value))

        case "in", "infolder", "parent":
            guard !value.isEmpty else { return nil }
            if value.hasPrefix("/") || value.hasPrefix("~") {
                return .filter(.pathUnder(SearchPath.normalize(value)))
            }
            return .filter(.pathContains(value))

        case "content":
            guard !value.isEmpty else { return nil }
            return .content(value)

        case "size":
            guard let predicate = SizePredicate.parse(value) else { return nil }
            return .filter(.size(predicate))

        case "dm", "modified", "date":
            guard let predicate = DatePredicate.parse(value) else { return nil }
            return .filter(.modified(predicate))

        default:
            return .plain(token)
        }
    }

    private static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isQuoted = false
        var iterator = query.makeIterator()

        while let character = iterator.next() {
            if character == "\"" {
                isQuoted.toggle()
                continue
            }

            if character == "\\" && isQuoted, let next = iterator.next() {
                current.append(next)
                continue
            }

            if character.isWhitespace && !isQuoted {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func makeMatcher(term: String, options: SearchOptions) throws -> Matcher {
        var scopedOptions = options
        scopedOptions.query = term
        return try Matcher(options: scopedOptions)
    }
}

private enum SearchQueryClause {
    case plain(String)
    case content(String)
    case filter(SearchQueryFilter)
}

struct CompiledSearchQuery: Sendable {
    let plan: SearchQueryPlan
    let plainMatchers: [Matcher]
    let explicitContentMatchers: [Matcher]
    let excludedMatchers: [Matcher]

    var matchesPinyin: Bool {
        guard !plan.plainTerms.isEmpty else { return false }
        return plan.plainTerms.allSatisfy { term in
            term.range(of: "^[a-zA-Z0-9\\s]+$", options: .regularExpression) != nil
        }
    }

    var hasExplicitContentFilter: Bool {
        !explicitContentMatchers.isEmpty
    }

    /// The literal term used for relevance ranking. Only substring mode has
    /// literal semantics; the longest plain term is the most selective.
    func rankingTerm(options: SearchOptions) -> String? {
        guard options.matchMode == .substring else { return nil }
        return plan.plainTerms.max { $0.count < $1.count }
    }

    func contentMatchers(for options: SearchOptions) -> [Matcher] {
        if hasExplicitContentFilter {
            return explicitContentMatchers
        }
        if options.target == .name {
            return []
        }
        return plainMatchers
    }

    func shouldRunContentBranch(options: SearchOptions) -> Bool {
        hasExplicitContentFilter || options.target == .content || (options.target == .both && !plainMatchers.isEmpty)
    }

    func matchesNameFilter(_ name: String, matchesPinyin: Bool = false) -> Bool {
        if plainMatchers.isEmpty { return true }
        return plainMatchers.allSatisfy { matcher in
            if matcher.matches(name) { return true }
            if matchesPinyin, SearchPath.containsHan(name) {
                let pinyin = SearchPath.pinyinFirstLetters(from: name)
                return matcher.matches(pinyin)
            }
            return false
        }
    }

    func matchesNameBranch(name: String, node: IndexedFileNode, path: String, options: SearchOptions, matchesPinyin: Bool = false) -> Bool {
        guard options.target != .content, !hasExplicitContentFilter else { return false }
        guard matchesBase(node, path: path, options: options) else { return false }
        return plainMatchers.allSatisfy { matcher in
            if matcher.matches(name) { return true }
            if matchesPinyin, SearchPath.containsHan(name) {
                let pinyin = SearchPath.pinyinFirstLetters(from: name)
                return matcher.matches(pinyin)
            }
            return false
        }
    }

    func matchesContentCandidate(name: String, node: IndexedFileNode, path: String, options: SearchOptions, matchesPinyin: Bool = false) -> Bool {
        guard !node.isDirectory, matchesBase(node, path: path, options: options) else { return false }
        if hasExplicitContentFilter {
            return plainMatchers.allSatisfy { matcher in
                if matcher.matches(name) { return true }
                if matchesPinyin, SearchPath.containsHan(name) {
                    let pinyin = SearchPath.pinyinFirstLetters(from: name)
                    return matcher.matches(pinyin)
                }
                return false
            }
        }
        return true
    }

    private func matchesBase(_ node: IndexedFileNode, path: String, options: SearchOptions) -> Bool {
        guard node.isVisible(with: options) else { return false }
        guard plan.filters.allSatisfy({ $0.matches(node: node, path: path, options: options) }) else { return false }
        guard !plan.excludedFilters.contains(where: { $0.matches(node: node, path: path, options: options) }) else { return false }
        let shortName = node.name.hasPrefix("/") ? (node.name as NSString).lastPathComponent : node.name
        guard !excludedMatchers.contains(where: { $0.matches(shortName) || $0.matches(path) }) else { return false }
        return true
    }
}

enum NodeKindFilter: Sendable, Equatable {
    case file
    case folder
}

enum SearchQueryFilter: Sendable, Equatable {
    case `extensionIs`(String)
    case kind(NodeKindFilter)
    case kindAndName(NodeKindFilter, String)
    case pathContains(String)
    case pathUnder(String)
    case size(SizePredicate)
    case modified(DatePredicate)

    func matches(node: IndexedFileNode, path: String, options: SearchOptions) -> Bool {
        switch self {
        case .extensionIs(let ext):
            return !node.isDirectory && (path as NSString).pathExtension.lowercased() == ext

        case .kind(.file):
            return !node.isDirectory

        case .kind(.folder):
            return node.isDirectory

        case .kindAndName(let kind, let value):
            guard SearchQueryFilter.kind(kind).matches(node: node, path: path, options: options) else { return false }
            let shortName = node.name.hasPrefix("/") ? (node.name as NSString).lastPathComponent : node.name
            return textContains(shortName, value, caseSensitive: options.caseSensitive)

        case .pathContains(let value):
            return textContains(path, value, caseSensitive: options.caseSensitive)

        case .pathUnder(let ancestor):
            return SearchPath.hasNormalizedPrefix(path, of: ancestor)

        case .size(let predicate):
            return !node.isDirectory && predicate.matches(node.size)

        case .modified(let predicate):
            let modifiedDate = Date(timeIntervalSinceReferenceDate: node.modifiedTime)
            return predicate.matches(modifiedDate)
        }
    }

    private func textContains(_ text: String, _ needle: String, caseSensitive: Bool) -> Bool {
        text.range(of: needle, options: caseSensitive ? [] : [.caseInsensitive]) != nil
    }
}

enum ComparisonOperator: Sendable, Equatable {
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
    case equal
}

struct SizePredicate: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case comparison(ComparisonOperator, Int64)
        case range(Int64, Int64)
    }

    let kind: Kind

    func matches(_ size: Int64) -> Bool {
        switch kind {
        case .comparison(.lessThan, let value):
            return size < value
        case .comparison(.lessThanOrEqual, let value):
            return size <= value
        case .comparison(.greaterThan, let value):
            return size > value
        case .comparison(.greaterThanOrEqual, let value):
            return size >= value
        case .comparison(.equal, let value):
            return size == value
        case .range(let lower, let upper):
            return size >= lower && size <= upper
        }
    }

    static func parse(_ raw: String) -> SizePredicate? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        if let range = value.range(of: "..") {
            let lowerRaw = String(value[..<range.lowerBound])
            let upperRaw = String(value[range.upperBound...])
            guard let lower = parseByteCount(lowerRaw),
                  let upper = parseByteCount(upperRaw),
                  lower <= upper else { return nil }
            return SizePredicate(kind: .range(lower, upper))
        }

        let operators: [(String, ComparisonOperator)] = [
            (">=", .greaterThanOrEqual),
            ("<=", .lessThanOrEqual),
            (">", .greaterThan),
            ("<", .lessThan),
            ("=", .equal),
        ]

        for (prefix, op) in operators where value.hasPrefix(prefix) {
            let numberRaw = String(value.dropFirst(prefix.count))
            guard let bytes = parseByteCount(numberRaw) else { return nil }
            return SizePredicate(kind: .comparison(op, bytes))
        }

        guard let bytes = parseByteCount(value) else { return nil }
        return SizePredicate(kind: .comparison(.equal, bytes))
    }

    private static func parseByteCount(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pattern = #"^([0-9]+(?:\.[0-9]+)?)(b|kb|k|mb|m|gb|g)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let numberRange = Range(match.range(at: 1), in: trimmed) else { return nil }

        let number = Double(trimmed[numberRange]) ?? 0
        let unit: String
        if let unitRange = Range(match.range(at: 2), in: trimmed) {
            unit = String(trimmed[unitRange])
        } else {
            unit = "b"
        }

        let multiplier: Double = switch unit {
        case "g", "gb": 1024 * 1024 * 1024
        case "m", "mb": 1024 * 1024
        case "k", "kb": 1024
        default: 1
        }
        return Int64((number * multiplier).rounded())
    }
}

struct DatePredicate: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case range(Date, Date)
        case comparison(ComparisonOperator, Date)
    }

    let kind: Kind

    func matches(_ date: Date) -> Bool {
        switch kind {
        case .range(let start, let end):
            return date >= start && date < end
        case .comparison(.lessThan, let value):
            return date < value
        case .comparison(.lessThanOrEqual, let value):
            return date <= value
        case .comparison(.greaterThan, let value):
            return date > value
        case .comparison(.greaterThanOrEqual, let value):
            return date >= value
        case .comparison(.equal, let value):
            let calendar = Calendar.current
            return calendar.isDate(date, inSameDayAs: value)
        }
    }

    static func parse(_ raw: String, now: Date = Date()) -> DatePredicate? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        switch value {
        case "today":
            return DatePredicate(kind: .range(today, calendar.date(byAdding: .day, value: 1, to: today) ?? now))
        case "yesterday":
            let start = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            return DatePredicate(kind: .range(start, today))
        case "pastweek", "lastweek":
            return DatePredicate(kind: .range(calendar.date(byAdding: .day, value: -7, to: now) ?? now, now))
        case "pastmonth", "lastmonth":
            return DatePredicate(kind: .range(calendar.date(byAdding: .month, value: -1, to: now) ?? now, now))
        case "pastyear", "lastyear":
            return DatePredicate(kind: .range(calendar.date(byAdding: .year, value: -1, to: now) ?? now, now))
        default:
            break
        }

        let operators: [(String, ComparisonOperator)] = [
            (">=", .greaterThanOrEqual),
            ("<=", .lessThanOrEqual),
            (">", .greaterThan),
            ("<", .lessThan),
            ("=", .equal),
        ]
        for (prefix, op) in operators where value.hasPrefix(prefix) {
            let dateRaw = String(value.dropFirst(prefix.count))
            guard let date = parseISODate(dateRaw) else { return nil }
            return DatePredicate(kind: .comparison(op, date))
        }

        guard let date = parseISODate(value) else { return nil }
        return DatePredicate(kind: .comparison(.equal, date))
    }

    private static func parseISODate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }
}
