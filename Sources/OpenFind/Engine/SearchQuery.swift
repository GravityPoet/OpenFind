import Foundation

struct SearchQueryPlan: Sendable, Equatable {
    fileprivate var expression: SearchQueryExpression = .all
    var plainTerms: [String] = []
    var explicitContentTerms: [String] = []
    var excludedTerms: [String] = []
    var filters: [SearchQueryFilter] = []
    var excludedFilters: [SearchQueryFilter] = []
    var parseError = false

    static func parse(_ query: String) -> SearchQueryPlan {
        var plan = SearchQueryPlan()
        guard let expression = SearchQueryExpressionParser.parse(query) else {
            plan.parseError = true
            return plan
        }
        plan.expression = expression
        expression.collectLegacyTerms(into: &plan, negated: false)
        return plan
    }

    fileprivate mutating func apply(_ clause: SearchQueryClause, negated: Bool) {
        switch (negated, clause) {
        case (false, .plain(let value, _)):
            plainTerms.append(value)
        case (true, .plain(let value, _)):
            excludedTerms.append(value)
        case (false, .content(let value)):
            explicitContentTerms.append(value)
        case (true, .content):
            break
        case (_, .regex):
            break
        case (false, .filter(let filter)):
            filters.append(filter)
        case (true, .filter(let filter)):
            excludedFilters.append(filter)
        }
    }

    func compile(options: SearchOptions) throws -> CompiledSearchQuery {
        if parseError { throw SearchQueryError.invalidExpression }
        let plainMatchers = try plainTerms.map { try makeMatcher(term: $0, options: options) }
        let contentMatchers = try explicitContentTerms.map { try makeMatcher(term: $0, options: options) }
        let excludedMatchers = try excludedTerms.map { try makeMatcher(term: $0, options: options) }
        return CompiledSearchQuery(
            plan: self,
            expression: try expression.compile(options: options),
            plainMatchers: plainMatchers,
            explicitContentMatchers: contentMatchers,
            excludedMatchers: excludedMatchers,
            matchesPinyin: Self.termsCanMatchPinyin(plainTerms),
            simpleNameSubstring: CompiledSimpleNameSubstring(plan: self, options: options)
        )
    }

    private static func termsCanMatchPinyin(_ terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        return terms.allSatisfy { term in
            !term.isEmpty && term.unicodeScalars.allSatisfy { scalar in
                let value = scalar.value
                return (0x41...0x5A).contains(value)
                    || (0x61...0x7A).contains(value)
                    || (0x30...0x39).contains(value)
                    || CharacterSet.whitespacesAndNewlines.contains(scalar)
            }
        }
    }

    fileprivate static func parseClauses(_ token: String, quoted: Bool) -> [SearchQueryClause]? {
        guard let separator = token.firstIndex(of: ":") else {
            if !quoted, let filter = parseExtensionGlob(token) {
                return [.filter(filter)]
            }
            return [.plain(token, literal: quoted)]
        }

        let key = token[..<separator].lowercased()
        let value = String(token[token.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)

        switch key {
        case "ext", "extension":
            guard let extensions = parseExtensions(value) else { return nil }
            return [.filter(.extensionIn(extensions))]

        case "file":
            if value.isEmpty { return [.filter(.kind(.file))] }
            return [.filter(.kindAndName(.file, value))]

        case "folder", "dir":
            if value.isEmpty { return [.filter(.kind(.folder))] }
            return [.filter(.kindAndName(.folder, value))]

        case "path":
            guard !value.isEmpty else { return nil }
            return [.filter(.pathContains(value))]

        case "parent":
            guard let path = parseAbsoluteScope(value) else { return nil }
            return [.filter(.directChildren(path))]

        case "in", "infolder":
            guard let path = parseAbsoluteScope(value) else { return nil }
            return [.filter(.descendantOf(path))]

        case "nosubfolders":
            guard let path = parseAbsoluteScope(value) else { return nil }
            return [.filter(.withoutSubfolders(path))]

        case "content":
            guard !value.isEmpty else { return nil }
            return [.content(value)]

        case "type":
            guard let extensions = typeExtensions(for: value) else { return nil }
            return [.filter(.extensionIn(extensions))]

        case "audio", "video", "doc", "exe":
            guard let extensions = macroExtensions(for: String(key)) else { return nil }
            var clauses: [SearchQueryClause] = [.filter(.extensionIn(extensions))]
            if !value.isEmpty {
                clauses.append(.plain(value, literal: quoted))
            }
            return clauses

        case "size":
            guard let predicate = SizePredicate.parse(value) else { return nil }
            return [.filter(.size(predicate))]

        case "dm", "modified", "date", "datemodified":
            guard let predicate = DatePredicate.parse(value) else { return nil }
            return [.filter(.modified(predicate))]

        case "dc", "created", "datecreated":
            guard let predicate = DatePredicate.parse(value) else { return nil }
            return [.filter(.created(predicate))]

        case "tag", "t":
            let tags = value.split(separator: ";").map(String.init).filter { !$0.isEmpty }
            guard !tags.isEmpty else { return nil }
            return [.filter(.tagContains(tags))]

        case "regex":
            guard !value.isEmpty else { return nil }
            return [.regex(value)]

        default:
            return [.plain(token, literal: quoted)]
        }
    }

    private static func parseAbsoluteScope(_ raw: String) -> String? {
        guard raw.hasPrefix("/") || raw.hasPrefix("~") else { return nil }
        return SearchPath.normalize(raw)
    }

    private static func parseExtensionGlob(_ token: String) -> SearchQueryFilter? {
        guard token.hasPrefix("*.") else { return nil }
        let rawExtension = String(token.dropFirst(2))
        guard let extensions = parseExtensions(rawExtension) else { return nil }
        return .extensionIn(extensions)
    }

    private static func parseExtensions(_ raw: String) -> Set<String>? {
        let extensions = raw
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))).lowercased() }
            .filter { !$0.isEmpty }
        guard !extensions.isEmpty else { return nil }
        return Set(extensions)
    }

    private static func macroExtensions(for key: String) -> Set<String>? {
        switch key {
        case "audio":
            return typeExtensions(for: "audio")
        case "video":
            return typeExtensions(for: "video")
        case "doc":
            return typeExtensions(for: "doc")
        case "exe":
            return typeExtensions(for: "exe")
        default:
            return nil
        }
    }

    private static func typeExtensions(for raw: String) -> Set<String>? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "picture", "pictures", "image", "images", "photo", "photos":
            return ["jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp", "svg"]
        case "video", "videos", "movie", "movies":
            return ["mov", "mp4", "m4v", "avi", "mkv", "webm", "hevc"]
        case "audio", "audios", "music", "song", "songs":
            return ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg"]
        case "doc", "docs", "document", "documents", "text", "office":
            return ["txt", "rtf", "md", "pdf", "doc", "docx", "pages", "odt"]
        case "presentation", "presentations", "ppt", "slides":
            return ["ppt", "pptx", "key", "odp"]
        case "spreadsheet", "spreadsheets", "xls", "excel", "sheet", "sheets":
            return ["xls", "xlsx", "numbers", "csv", "tsv", "ods"]
        case "pdf":
            return ["pdf"]
        case "archive", "archives", "compressed", "zip":
            return ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg"]
        case "code", "source", "dev":
            return ["swift", "rs", "ts", "tsx", "js", "jsx", "py", "rb", "go", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "cs", "php", "html", "css", "json", "xml", "yaml", "yml", "toml", "sh"]
        case "exe", "exec", "executable", "executables", "program", "programs", "app", "apps":
            return ["app", "command", "tool", "sh", "bin", "xpc", "appex"]
        default:
            return nil
        }
    }

    private func makeMatcher(term: String, options: SearchOptions) throws -> Matcher {
        var scopedOptions = options
        scopedOptions.query = term
        return try Matcher(options: scopedOptions)
    }
}

enum SearchQueryError: Error {
    case invalidExpression
}

fileprivate indirect enum SearchQueryExpression: Sendable, Equatable {
    case all
    case clause(SearchQueryClause)
    case and([SearchQueryExpression])
    case or([SearchQueryExpression])
    case not(SearchQueryExpression)

    func collectLegacyTerms(into plan: inout SearchQueryPlan, negated: Bool) {
        switch self {
        case .all:
            return
        case .clause(let clause):
            plan.apply(clause, negated: negated)
        case .and(let children), .or(let children):
            for child in children {
                child.collectLegacyTerms(into: &plan, negated: negated)
            }
        case .not(let child):
            child.collectLegacyTerms(into: &plan, negated: !negated)
        }
    }

    func compile(options: SearchOptions) throws -> CompiledSearchExpression {
        switch self {
        case .all:
            return .all
        case .clause(let clause):
            return .predicate(try CompiledQueryPredicate(clause: clause, options: options))
        case .and(let children):
            return .and(try children.map { try $0.compile(options: options) })
        case .or(let children):
            return .or(try children.map { try $0.compile(options: options) })
        case .not(let child):
            return .not(try child.compile(options: options))
        }
    }

    /// Plain terms that every successful branch must satisfy. Intersecting OR
    /// branches is essential: using a term present in only one branch as an
    /// index prefilter would incorrectly hide matches from the other branch.
    func requiredPositivePlainTerms() -> Set<String> {
        switch self {
        case .all, .not:
            return []
        case .clause(.plain(let value, _)):
            return [value]
        case .clause:
            return []
        case .and(let children):
            return children.reduce(into: Set<String>()) { terms, child in
                terms.formUnion(child.requiredPositivePlainTerms())
            }
        case .or(let children):
            guard var required = children.first?.requiredPositivePlainTerms() else { return [] }
            for child in children.dropFirst() {
                required.formIntersection(child.requiredPositivePlainTerms())
            }
            return required
        }
    }

    /// Literal content terms that every successful Boolean branch must
    /// contain. OR branches use intersection; negated terms are never safe as
    /// an exclusion prefilter. Explicit `content:` clauses always use
    /// substring semantics, while plain terms are eligible only when their
    /// active match mode makes the literal a necessary substring.
    func requiredPositiveContentTerms(options: SearchOptions) -> Set<String> {
        switch self {
        case .all, .not:
            return []
        case .clause(.content(let value)):
            return [value]
        case .clause(.plain(let value, _)):
            guard options.target != .name,
                  options.matchMode == .substring || options.matchMode == .wholeWord,
                  !value.contains("/"),
                  !CompiledTextPredicate.hasWildcard(value) else { return [] }
            return [value]
        case .clause:
            return []
        case .and(let children):
            return children.reduce(into: Set<String>()) { terms, child in
                terms.formUnion(child.requiredPositiveContentTerms(options: options))
            }
        case .or(let children):
            guard var required = children.first?.requiredPositiveContentTerms(options: options) else {
                return []
            }
            for child in children.dropFirst() {
                required.formIntersection(child.requiredPositiveContentTerms(options: options))
            }
            return required
        }
    }
}

fileprivate enum SearchQueryClause: Sendable, Equatable {
    case plain(String, literal: Bool)
    case content(String)
    case regex(String)
    case filter(SearchQueryFilter)
}

private enum QueryToken: Equatable {
    case word(String, quoted: Bool)
    case and
    case or
    case not
    case leftGroup
    case rightGroup
}

private struct SearchQueryExpressionParser {
    private let tokens: [QueryToken]
    private var index = 0

    static func parse(_ query: String) -> SearchQueryExpression? {
        guard let tokens = tokenize(query) else { return nil }
        guard !tokens.isEmpty else { return .all }
        var parser = SearchQueryExpressionParser(tokens: tokens)
        guard let expression = parser.parseAnd(), parser.isAtEnd else { return nil }
        return expression
    }

    private var isAtEnd: Bool { index >= tokens.count }

    private var current: QueryToken? {
        isAtEnd ? nil : tokens[index]
    }

    private mutating func advance() -> QueryToken? {
        guard !isAtEnd else { return nil }
        defer { index += 1 }
        return tokens[index]
    }

    private mutating func parseAnd() -> SearchQueryExpression? {
        guard var children = parseOr().map({ [$0] }) else { return nil }
        while true {
            if current == .and {
                _ = advance()
                guard let rhs = parseOr() else { return nil }
                children.append(rhs)
            } else if startsPrimary(current) {
                guard let rhs = parseOr() else { return nil }
                children.append(rhs)
            } else {
                break
            }
        }
        return children.count == 1 ? children[0] : .and(children)
    }

    private mutating func parseOr() -> SearchQueryExpression? {
        guard var children = parseNot().map({ [$0] }) else { return nil }
        while current == .or {
            _ = advance()
            guard let rhs = parseNot() else { return nil }
            children.append(rhs)
        }
        return children.count == 1 ? children[0] : .or(children)
    }

    private mutating func parseNot() -> SearchQueryExpression? {
        if current == .not {
            _ = advance()
            guard let child = parseNot() else { return nil }
            return .not(child)
        }
        return parsePrimary()
    }

    private mutating func parsePrimary() -> SearchQueryExpression? {
        guard let token = advance() else { return nil }
        switch token {
        case .word(let value, let quoted):
            guard let clauses = SearchQueryPlan.parseClauses(value, quoted: quoted), !clauses.isEmpty else { return nil }
            let expressions = clauses.map { SearchQueryExpression.clause($0) }
            return expressions.count == 1 ? expressions[0] : .and(expressions)
        case .leftGroup:
            guard let expression = parseAnd(), current == .rightGroup else { return nil }
            _ = advance()
            return expression
        case .and, .or, .not, .rightGroup:
            return nil
        }
    }

    private func startsPrimary(_ token: QueryToken?) -> Bool {
        switch token {
        case .word, .not, .leftGroup:
            return true
        default:
            return false
        }
    }

    private static func tokenize(_ query: String) -> [QueryToken]? {
        var tokens: [QueryToken] = []
        var current = ""
        var isQuoted = false
        var wordWasQuoted = false
        var angleGroupDepth = 0
        var iterator = query.makeIterator()

        func flushWord() {
            guard !current.isEmpty else { return }
            let word = current
            current.removeAll(keepingCapacity: true)
            defer { wordWasQuoted = false }
            guard !wordWasQuoted else {
                tokens.append(.word(word, quoted: true))
                return
            }
            switch word.uppercased() {
            case "AND":
                tokens.append(.and)
            case "OR":
                tokens.append(.or)
            case "NOT":
                tokens.append(.not)
            default:
                tokens.append(.word(word, quoted: false))
            }
        }

        while let character = iterator.next() {
            if character == "\"" {
                isQuoted.toggle()
                wordWasQuoted = true
                continue
            }

            if character == "\\" && isQuoted, let next = iterator.next() {
                current.append(next)
                continue
            }

            guard !isQuoted else {
                current.append(character)
                continue
            }

            switch character {
            case " ", "\t", "\n", "\r":
                flushWord()
            case "(":
                flushWord()
                tokens.append(.leftGroup)
            case ")":
                flushWord()
                tokens.append(.rightGroup)
            case "<":
                if current.isEmpty {
                    tokens.append(.leftGroup)
                    angleGroupDepth += 1
                } else {
                    current.append(character)
                }
            case ">":
                if angleGroupDepth > 0 && !isComparisonValueStart(current) {
                    flushWord()
                    tokens.append(.rightGroup)
                    angleGroupDepth -= 1
                } else {
                    current.append(character)
                }
            case "|":
                flushWord()
                tokens.append(.or)
            case "!":
                if current.isEmpty {
                    tokens.append(.not)
                } else {
                    current.append(character)
                }
            default:
                current.append(character)
            }
        }

        if isQuoted {
            return nil
        }
        if angleGroupDepth != 0 {
            return nil
        }
        flushWord()
        return tokens
    }

    private static func isComparisonValueStart(_ token: String) -> Bool {
        let lower = token.lowercased()
        return ["size:", "dm:", "modified:", "date:", "datemodified:", "dc:", "created:", "datecreated:"].contains(lower)
    }
}

fileprivate struct QueryMatchContext {
    let node: IndexedFileNode
    let name: String
    let path: String
    let options: SearchOptions
    let matchesPinyin: Bool
}

fileprivate indirect enum CompiledSearchExpression: Sendable {
    case all
    case predicate(CompiledQueryPredicate)
    case and([CompiledSearchExpression])
    case or([CompiledSearchExpression])
    case not(CompiledSearchExpression)

    func evaluate(context: QueryMatchContext, content: String?, plainTermsTargetContent: Bool) -> QueryMatchState {
        switch self {
        case .all:
            return .match
        case .predicate(let predicate):
            return predicate.evaluate(context: context, content: content, plainTermsTargetContent: plainTermsTargetContent)
        case .and(let children):
            return children.reduce(.match) { result, child in
                result.and(child.evaluate(context: context, content: content, plainTermsTargetContent: plainTermsTargetContent))
            }
        case .or(let children):
            return children.reduce(.noMatch) { result, child in
                result.or(child.evaluate(context: context, content: content, plainTermsTargetContent: plainTermsTargetContent))
            }
        case .not(let child):
            return child.evaluate(context: context, content: content, plainTermsTargetContent: plainTermsTargetContent).negated
        }
    }

    func evaluateNameOnly(name: String, matchesPinyin: Bool) -> QueryMatchState {
        switch self {
        case .all:
            return .match
        case .predicate(let predicate):
            return predicate.evaluateNameOnly(name: name, matchesPinyin: matchesPinyin)
        case .and(let children):
            return children.reduce(.match) { result, child in
                result.and(child.evaluateNameOnly(name: name, matchesPinyin: matchesPinyin))
            }
        case .or(let children):
            return children.reduce(.noMatch) { result, child in
                result.or(child.evaluateNameOnly(name: name, matchesPinyin: matchesPinyin))
            }
        case .not(let child):
            return child.evaluateNameOnly(name: name, matchesPinyin: matchesPinyin).negated
        }
    }

    var containsContentPredicate: Bool {
        switch self {
        case .all:
            return false
        case .predicate(let predicate):
            return predicate.isContentPredicate
        case .and(let children), .or(let children):
            return children.contains { $0.containsContentPredicate }
        case .not(let child):
            return child.containsContentPredicate
        }
    }
}

fileprivate enum QueryMatchState: Equatable {
    case match
    case noMatch
    case unknown

    func and(_ other: QueryMatchState) -> QueryMatchState {
        if self == .noMatch || other == .noMatch { return .noMatch }
        if self == .unknown || other == .unknown { return .unknown }
        return .match
    }

    func or(_ other: QueryMatchState) -> QueryMatchState {
        if self == .match || other == .match { return .match }
        if self == .unknown || other == .unknown { return .unknown }
        return .noMatch
    }

    var negated: QueryMatchState {
        switch self {
        case .match: return .noMatch
        case .noMatch: return .match
        case .unknown: return .unknown
        }
    }
}

fileprivate enum CompiledQueryPredicate: Sendable {
    case text(name: CompiledTextPredicate, content: Matcher?)
    case content(Matcher)
    case filter(SearchQueryFilter)

    init(clause: SearchQueryClause, options: SearchOptions) throws {
        switch clause {
        case .plain(let value, let literal):
            var contentOptions = options
            contentOptions.query = value
            if literal { contentOptions.matchMode = .substring }
            let contentMatcher = value.contains("/") ? nil : try Matcher(options: contentOptions)
            self = .text(
                name: try CompiledTextPredicate(term: value, literal: literal, options: options),
                content: contentMatcher
            )
        case .content(let value):
            var contentOptions = options
            contentOptions.query = value
            contentOptions.matchMode = .substring
            self = .content(try Matcher(options: contentOptions))
        case .regex(let value):
            self = .text(
                name: try CompiledTextPredicate(regex: value, options: options),
                content: nil
            )
        case .filter(let filter):
            self = .filter(filter)
        }
    }

    var isContentPredicate: Bool {
        if case .content = self { return true }
        return false
    }

    func evaluate(context: QueryMatchContext, content: String?, plainTermsTargetContent: Bool) -> QueryMatchState {
        switch self {
        case .text(let namePredicate, let contentMatcher):
            if plainTermsTargetContent, let contentMatcher {
                guard let content else { return .unknown }
                return contentMatcher.matches(content) ? .match : .noMatch
            }
            return namePredicate.matches(context: context) ? .match : .noMatch
        case .content(let matcher):
            guard let content else { return .unknown }
            return matcher.matches(content) ? .match : .noMatch
        case .filter(let filter):
            return filter.matches(node: context.node, path: context.path, options: context.options) ? .match : .noMatch
        }
    }

    func evaluateNameOnly(name: String, matchesPinyin: Bool) -> QueryMatchState {
        switch self {
        case .text(let namePredicate, _):
            return namePredicate.evaluateNameOnly(name: name, matchesPinyin: matchesPinyin)
        case .content, .filter:
            return .unknown
        }
    }
}

fileprivate struct CompiledTextPredicate: Sendable {
    private enum Kind: Sendable {
        case matcher(Matcher)
        case nameSubstring(
            needle: String,
            asciiFoldedNeedle: [UInt8]?,
            caseSensitive: Bool
        )
        case nameWildcard(String, caseSensitive: Bool)
        case pathSegments([CompiledPathSegment], caseSensitive: Bool)
    }

    private let kind: Kind

    init(term: String, literal: Bool = false, options: SearchOptions) throws {
        if options.matchMode == .substring {
            if term.contains("/") {
                kind = .pathSegments(CompiledPathSegment.parse(term), caseSensitive: options.caseSensitive)
            } else if Self.hasWildcard(term) && !literal {
                kind = .nameWildcard(term, caseSensitive: options.caseSensitive)
            } else {
                kind = .nameSubstring(
                    needle: term,
                    asciiFoldedNeedle: options.caseSensitive ? nil : Self.asciiFoldedBytes(term),
                    caseSensitive: options.caseSensitive
                )
            }
        } else {
            var scopedOptions = options
            scopedOptions.query = term
            kind = .matcher(try Matcher(options: scopedOptions))
        }
    }

    init(regex: String, options: SearchOptions) throws {
        kind = .matcher(try Self.makeRegexMatcher(regex, options: options))
    }

    static func makeRegexMatcher(_ regex: String, options: SearchOptions) throws -> Matcher {
        var regexOptions = options
        regexOptions.query = regex
        regexOptions.matchMode = .regex
        return try Matcher(options: regexOptions)
    }

    func matches(context: QueryMatchContext) -> Bool {
        switch kind {
        case .matcher(let matcher):
            if matcher.matches(context.name) { return true }
            if context.matchesPinyin, SearchPath.containsHan(context.name) {
                return matcher.matches(SearchPath.pinyinFirstLetters(from: context.name))
            }
            return false
        case .nameSubstring(let needle, let asciiFoldedNeedle, let caseSensitive):
            if Self.contains(
                context.name,
                needle: needle,
                asciiFoldedNeedle: asciiFoldedNeedle,
                caseSensitive: caseSensitive
            ) { return true }
            if context.matchesPinyin, SearchPath.containsHan(context.name) {
                return Self.contains(
                    SearchPath.pinyinFirstLetters(from: context.name),
                    needle: needle,
                    asciiFoldedNeedle: asciiFoldedNeedle,
                    caseSensitive: caseSensitive
                )
            }
            return false
        case .nameWildcard(let pattern, let caseSensitive):
            return Self.wildcardMatches(pattern: pattern, text: context.name, caseSensitive: caseSensitive)
        case .pathSegments(let segments, let caseSensitive):
            return Self.pathSegmentsMatch(segments, path: context.path, caseSensitive: caseSensitive)
        }
    }

    func evaluateNameOnly(name: String, matchesPinyin: Bool) -> QueryMatchState {
        switch kind {
        case .matcher(let matcher):
            if matcher.matches(name) { return .match }
            if matchesPinyin, SearchPath.containsHan(name),
               matcher.matches(SearchPath.pinyinFirstLetters(from: name)) {
                return .match
            }
            return .noMatch
        case .nameSubstring(let needle, let asciiFoldedNeedle, let caseSensitive):
            if Self.contains(
                name,
                needle: needle,
                asciiFoldedNeedle: asciiFoldedNeedle,
                caseSensitive: caseSensitive
            ) { return .match }
            if matchesPinyin, SearchPath.containsHan(name),
               Self.contains(
                   SearchPath.pinyinFirstLetters(from: name),
                   needle: needle,
                   asciiFoldedNeedle: asciiFoldedNeedle,
                   caseSensitive: caseSensitive
               ) {
                return .match
            }
            return .noMatch
        case .nameWildcard(let pattern, let caseSensitive):
            return Self.wildcardMatches(pattern: pattern, text: name, caseSensitive: caseSensitive) ? .match : .noMatch
        case .pathSegments:
            return .unknown
        }
    }

    fileprivate static func hasWildcard(_ text: String) -> Bool {
        text.contains("*") || text.contains("?")
    }

    fileprivate static func contains(_ text: String, needle: String, caseSensitive: Bool) -> Bool {
        contains(
            text,
            needle: needle,
            asciiFoldedNeedle: caseSensitive ? nil : asciiFoldedBytes(needle),
            caseSensitive: caseSensitive
        )
    }

    private static func contains(
        _ text: String,
        needle: String,
        asciiFoldedNeedle: [UInt8]?,
        caseSensitive: Bool
    ) -> Bool {
        if let asciiFoldedNeedle,
           let fastMatch = asciiCaseInsensitiveContains(text, needleBytes: asciiFoldedNeedle) {
            return fastMatch
        }
        return text.range(of: needle, options: caseSensitive ? [] : [.caseInsensitive]) != nil
    }

    private static func asciiFoldedBytes(_ text: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            guard byte < 0x80 else { return nil }
            bytes.append(asciiLowercased(byte))
        }
        return bytes
    }

    private static func asciiCaseInsensitiveContains(_ text: String, needleBytes: [UInt8]) -> Bool? {
        guard !needleBytes.isEmpty else { return true }

        if let contiguousResult = text.utf8.withContiguousStorageIfAvailable({ bytes -> Bool? in
            guard bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
            guard bytes.count >= needleBytes.count else { return false }
            let finalStart = bytes.count - needleBytes.count
            for start in 0...finalStart {
                var matched = true
                for offset in needleBytes.indices {
                    if asciiLowercased(bytes[start + offset]) != needleBytes[offset] {
                        matched = false
                        break
                    }
                }
                if matched { return true }
            }
            return false
        }) {
            return contiguousResult
        }

        let textBytes = text.utf8
        guard textBytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        var start = textBytes.startIndex
        while start != textBytes.endIndex {
            var textIndex = start
            var needleIndex = 0
            while needleIndex < needleBytes.count {
                guard textIndex != textBytes.endIndex else { return false }
                let textByte = textBytes[textIndex]
                if asciiLowercased(textByte) != needleBytes[needleIndex] { break }
                needleIndex += 1
                textIndex = textBytes.index(after: textIndex)
            }
            if needleIndex == needleBytes.count { return true }
            start = textBytes.index(after: start)
        }
        return false
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    fileprivate static func wildcardMatches(pattern: String, text: String, caseSensitive: Bool) -> Bool {
        let patternChars = Array(caseSensitive ? pattern : pattern.lowercased())
        let textChars = Array(caseSensitive ? text : text.lowercased())
        var p = 0
        var t = 0
        var star: Int?
        var matchAfterStar = 0

        while t < textChars.count {
            if p < patternChars.count && (patternChars[p] == "?" || patternChars[p] == textChars[t]) {
                p += 1
                t += 1
            } else if p < patternChars.count && patternChars[p] == "*" {
                star = p
                matchAfterStar = t
                p += 1
            } else if let star {
                p = star + 1
                matchAfterStar += 1
                t = matchAfterStar
            } else {
                return false
            }
        }

        while p < patternChars.count && patternChars[p] == "*" {
            p += 1
        }
        return p == patternChars.count
    }

    fileprivate static func pathTermMatches(_ term: String, path: String, caseSensitive: Bool) -> Bool {
        pathSegmentsMatch(CompiledPathSegment.parse(term), path: path, caseSensitive: caseSensitive)
    }

    private static func pathSegmentsMatch(_ segments: [CompiledPathSegment], path: String, caseSensitive: Bool) -> Bool {
        guard !segments.isEmpty else { return true }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return false }

        func match(patternIndex: Int, componentIndex: Int) -> Bool {
            if patternIndex == segments.count { return true }
            let segment = segments[patternIndex]
            if segment.isGlobstar {
                if patternIndex == segments.count - 1 { return true }
                for nextIndex in componentIndex...components.count {
                    if match(patternIndex: patternIndex + 1, componentIndex: nextIndex) {
                        return true
                    }
                }
                return false
            }
            guard componentIndex < components.count,
                  segment.matches(components[componentIndex], caseSensitive: caseSensitive) else { return false }
            return match(patternIndex: patternIndex + 1, componentIndex: componentIndex + 1)
        }

        for startIndex in 0..<components.count {
            if match(patternIndex: 0, componentIndex: startIndex) { return true }
        }
        return false
    }
}

fileprivate struct CompiledPathSegment: Sendable {
    private enum Rule: Sendable {
        case prefix
        case suffix
        case exact
        case contains
        case globstar
    }

    private let value: String
    private let rule: Rule

    var isGlobstar: Bool {
        if case .globstar = rule { return true }
        return false
    }

    static func parse(_ term: String) -> [CompiledPathSegment] {
        let leadingSlash = term.hasPrefix("/")
        let trailingSlash = term.hasSuffix("/") && term.count > 1
        let values = term.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !values.isEmpty else { return [] }

        return values.enumerated().map { index, value in
            if value == "**" {
                return CompiledPathSegment(value: value, rule: .globstar)
            }

            let rule: Rule
            if values.count == 1 {
                if leadingSlash && trailingSlash {
                    rule = .exact
                } else if leadingSlash {
                    rule = .prefix
                } else if trailingSlash {
                    rule = .suffix
                } else {
                    rule = .contains
                }
            } else if index == 0 {
                rule = leadingSlash ? .exact : .suffix
            } else if index == values.count - 1 {
                rule = trailingSlash ? .exact : .prefix
            } else {
                rule = .exact
            }
            return CompiledPathSegment(value: value, rule: rule)
        }
    }

    func matches(_ component: String, caseSensitive: Bool) -> Bool {
        switch rule {
        case .globstar:
            return true
        case .prefix:
            if CompiledTextPredicate.hasWildcard(value) {
                return CompiledTextPredicate.wildcardMatches(pattern: value + "*", text: component, caseSensitive: caseSensitive)
            }
            return caseAdjusted(component, caseSensitive).hasPrefix(caseAdjusted(value, caseSensitive))
        case .suffix:
            if CompiledTextPredicate.hasWildcard(value) {
                return CompiledTextPredicate.wildcardMatches(pattern: "*" + value, text: component, caseSensitive: caseSensitive)
            }
            return caseAdjusted(component, caseSensitive).hasSuffix(caseAdjusted(value, caseSensitive))
        case .exact:
            if CompiledTextPredicate.hasWildcard(value) {
                return CompiledTextPredicate.wildcardMatches(pattern: value, text: component, caseSensitive: caseSensitive)
            }
            return caseAdjusted(component, caseSensitive) == caseAdjusted(value, caseSensitive)
        case .contains:
            if CompiledTextPredicate.hasWildcard(value) {
                return CompiledTextPredicate.wildcardMatches(pattern: "*" + value + "*", text: component, caseSensitive: caseSensitive)
            }
            return CompiledTextPredicate.contains(component, needle: value, caseSensitive: caseSensitive)
        }
    }

    private func caseAdjusted(_ value: String, _ caseSensitive: Bool) -> String {
        caseSensitive ? value : value.lowercased()
    }
}

fileprivate struct CompiledSimpleNameSubstring: Sendable {
    let needle: String
    let needleBytes: [UInt8]?
    let foldedNeedle: [UInt8]?
    let lowercasedNeedle: String
    let caseSensitive: Bool

    init?(plan: SearchQueryPlan, options: SearchOptions) {
        guard options.target != .content,
              options.matchMode == .substring,
              plan.plainTerms.count == 1,
              plan.excludedTerms.isEmpty,
              plan.filters.isEmpty,
              plan.excludedFilters.isEmpty else {
            return nil
        }
        let needle = plan.plainTerms[0]
        guard !needle.isEmpty,
              !needle.contains("/"),
              !CompiledTextPredicate.hasWildcard(needle) else {
            return nil
        }
        self.needle = needle
        let bytes = Array(needle.utf8)
        if bytes.allSatisfy({ $0 < 0x80 }) {
            needleBytes = bytes
            foldedNeedle = bytes.map { byte in
                (65...90).contains(byte) ? byte + 32 : byte
            }
        } else {
            needleBytes = nil
            foldedNeedle = nil
        }
        lowercasedNeedle = needle.lowercased()
        caseSensitive = options.caseSensitive
    }
}

struct CompiledSearchQuery: Sendable {
    let plan: SearchQueryPlan
    fileprivate let expression: CompiledSearchExpression
    let plainMatchers: [Matcher]
    let explicitContentMatchers: [Matcher]
    let excludedMatchers: [Matcher]
    let matchesPinyin: Bool
    fileprivate let simpleNameSubstring: CompiledSimpleNameSubstring?

    var hasExplicitContentFilter: Bool { expression.containsContentPredicate }

    /// The literal term used for relevance ranking. Only substring mode has
    /// literal semantics; the longest plain term is the most selective.
    func rankingTerm(options: SearchOptions) -> String? {
        guard options.matchMode == .substring else { return nil }
        return plan.plainTerms.max { $0.count < $1.count }
    }

    /// A literal ASCII substring that is provably required by every boolean
    /// branch. It is safe for lossless character/bigram/trigram prefiltering;
    /// all other query shapes fall back to the complete unique-name scan.
    func requiredNameIndexTerm(options: SearchOptions) -> String? {
        guard options.matchMode == .substring else { return nil }
        return plan.expression.requiredPositivePlainTerms()
            .filter { term in
                !term.contains("/")
                    && !CompiledTextPredicate.hasWildcard(term)
                    && !term.isEmpty
                    && term.utf8.allSatisfy { $0 < 0x80 }
            }
            .max { $0.utf8.count < $1.utf8.count }
    }

    /// A required ASCII literal suitable for SQLite's trigram prefilter. The
    /// restriction is deliberate: Foundation's full Unicode matching remains
    /// authoritative for every term whose normalization/case semantics cannot
    /// be proven identical to the FTS tokenizer.
    func requiredContentIndexTerm(options: SearchOptions) -> String? {
        plan.expression.requiredPositiveContentTerms(options: options)
            .filter { term in
                term.utf8.count >= 3
                    && term.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
            }
            .max { $0.utf8.count < $1.utf8.count }
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

    /// Name, path, kind, extension, hidden, and package predicates are complete
    /// in the query-ready topology. Size/timestamp predicates and every content
    /// branch must wait for the enriched snapshot so zero-valued placeholders
    /// can never create false positives or hide valid results.
    func requiresCompleteMetadata(options: SearchOptions) -> Bool {
        shouldRunContentBranch(options: options)
            || plan.filters.contains(where: \.requiresCompleteMetadata)
            || plan.excludedFilters.contains(where: \.requiresCompleteMetadata)
    }

    func requiresContentScan(options: SearchOptions) -> Bool {
        hasExplicitContentFilter || (options.target != .name && !plainMatchers.isEmpty)
    }

    /// Returns the only content predicate that can be evaluated losslessly by
    /// the bounded streaming reader.  The reader is deliberately restricted
    /// to one literal substring: Boolean expressions, regular expressions,
    /// wildcard/whole-word matching, and metadata filters continue through the
    /// authoritative full-text path rather than being approximated.
    func streamingContentLiteral(options: SearchOptions) -> String? {
        guard options.maxContentFileSize == 0,
              plan.excludedTerms.isEmpty,
              plan.filters.isEmpty,
              plan.excludedFilters.isEmpty,
              plan.plainTerms.count + plan.explicitContentTerms.count == 1 else {
            return nil
        }
        let hasExplicitLiteral = plan.explicitContentTerms.count == 1
        if !hasExplicitLiteral {
            guard options.target != .name,
                  options.matchMode == .substring else { return nil }
        }
        let value = hasExplicitLiteral
            ? plan.explicitContentTerms[0]
            : plan.plainTerms[0]
        guard !value.isEmpty,
              !value.contains("/"),
              !CompiledTextPredicate.hasWildcard(value),
              value.utf8.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        return value
    }

    func matchesNameFilter(_ name: String, matchesPinyin: Bool = false) -> Bool {
        expression.evaluateNameOnly(name: name, matchesPinyin: matchesPinyin) != .noMatch
    }

    /// Matches the common single-literal query and returns the same relevance
    /// class used by `SearchRanking`. ASCII names are matched and scored in one
    /// byte pass, avoiding a second `lowercased()` allocation for every hit in
    /// a multi-million-result search. Unicode and pinyin keep the complete
    /// Foundation-backed semantics as a lossless fallback.
    func simpleNameSubstringMatchScore(
        _ name: String,
        options: SearchOptions,
        matchesPinyin: Bool
    ) -> UInt8? {
        guard isSimpleNameSubstring(options: options) else { return nil }
        return simpleNameSubstringMatchScoreAssumingSimple(
            name,
            options: options,
            matchesPinyin: matchesPinyin
        )
    }

    /// `SearchIndex.nameMatches` establishes this invariant once per query.
    /// Keeping the checked entry point above protects other callers while this
    /// hot path avoids recursively re-inspecting the compiled expression for
    /// every unique filename in a multi-million-node index.
    func simpleNameSubstringMatchScoreAssumingSimple(
        _ name: String,
        options: SearchOptions,
        matchesPinyin: Bool
    ) -> UInt8? {
        guard let compiled = simpleNameSubstring else { return nil }
        if let needleBytes = compiled.needleBytes,
           let foldedNeedle = compiled.foldedNeedle {
            switch Self.asciiSubstringMatchScore(
                name,
                needleBytes: needleBytes,
                foldedNeedle: foldedNeedle,
                caseSensitive: compiled.caseSensitive
            ) {
            case .match(let score):
                return score
            case .noMatch:
                return nil
            case .unsupported:
                break
            }
        }

        let matchesName = CompiledTextPredicate.contains(
            name,
            needle: compiled.needle,
            caseSensitive: compiled.caseSensitive
        )
        let matchesTransliteration = !matchesName
            && matchesPinyin
            && SearchPath.containsHan(name)
            && CompiledTextPredicate.contains(
                SearchPath.pinyinFirstLetters(from: name),
                needle: compiled.needle,
                caseSensitive: compiled.caseSensitive
            )
        guard matchesName || matchesTransliteration else { return nil }

        let lowerName = name.lowercased()
        let lowerNeedle = compiled.lowercasedNeedle
        if lowerName == lowerNeedle { return 0 }
        if (lowerName as NSString).deletingPathExtension == lowerNeedle { return 1 }
        guard let range = lowerName.range(of: lowerNeedle) else { return 4 }
        if range.lowerBound == lowerName.startIndex { return 2 }
        let before = lowerName[lowerName.index(before: range.lowerBound)]
        return (before.isLetter || before.isNumber) ? 4 : 3
    }

    private enum ASCIISubstringMatchScore {
        case unsupported
        case noMatch
        case match(UInt8)
    }

    private static func asciiSubstringMatchScore(
        _ name: String,
        needleBytes: [UInt8],
        foldedNeedle: [UInt8],
        caseSensitive: Bool
    ) -> ASCIISubstringMatchScore {
        guard !needleBytes.isEmpty, needleBytes.count == foldedNeedle.count else {
            return .noMatch
        }

        guard let result = name.utf8.withContiguousStorageIfAvailable({ bytes -> ASCIISubstringMatchScore in
            guard bytes.allSatisfy({ $0 < 0x80 }) else { return .unsupported }
            guard bytes.count >= needleBytes.count else { return .noMatch }

            var firstFoldedMatch: Int?
            var queryMatched = false
            let finalStart = bytes.count - needleBytes.count
            for start in 0...finalStart {
                var foldedMatch = true
                var exactCaseMatch = true
                for offset in needleBytes.indices {
                    let byte = bytes[start + offset]
                    if asciiLowercased(byte) != foldedNeedle[offset] {
                        foldedMatch = false
                        exactCaseMatch = false
                        break
                    }
                    if byte != needleBytes[offset] { exactCaseMatch = false }
                }
                guard foldedMatch else { continue }
                if firstFoldedMatch == nil { firstFoldedMatch = start }
                if !caseSensitive || exactCaseMatch { queryMatched = true }
                if queryMatched && firstFoldedMatch != nil { break }
            }
            guard queryMatched, let matchStart = firstFoldedMatch else {
                return .noMatch
            }

            if bytes.count == needleBytes.count { return .match(0) }
            if let lastDot = bytes.lastIndex(of: UInt8(ascii: ".")),
               lastDot > 0,
               lastDot < bytes.count - 1,
               lastDot == needleBytes.count {
                var stemMatches = true
                for offset in needleBytes.indices where asciiLowercased(bytes[offset]) != foldedNeedle[offset] {
                    stemMatches = false
                    break
                }
                if stemMatches { return .match(1) }
            }
            if matchStart == 0 { return .match(2) }
            let before = bytes[matchStart - 1]
            let isASCIIWord = (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(asciiLowercased(before))
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(before)
            return .match(isASCIIWord ? 4 : 3)
        }) else { return .unsupported }
        return result
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    /// The overwhelmingly common broad query shape: one literal substring
    /// searched in names with no boolean/filter branch that needs the full
    /// path-aware expression evaluator.  `nameMatches` has already applied
    /// `matchesNameFilter` once per unique filename, so evaluating the same
    /// predicate again for every duplicate node is wasted work.
    func isSimpleNameSubstring(options: SearchOptions) -> Bool {
        simpleNameSubstring != nil
            && options.target != .content
            && options.matchMode == .substring
            && !hasExplicitContentFilter
            && plan.plainTerms.count == 1
            && plan.excludedTerms.isEmpty
            && plan.filters.isEmpty
            && plan.excludedFilters.isEmpty
            && !plan.plainTerms[0].isEmpty
            && !plan.plainTerms[0].contains("/")
            && !CompiledTextPredicate.hasWildcard(plan.plainTerms[0])
    }

    func matchesNameBranch(name: String, node: IndexedFileNode, path: String, options: SearchOptions, matchesPinyin: Bool = false) -> Bool {
        guard options.target != .content, !hasExplicitContentFilter else { return false }
        guard node.isVisible(with: options) else { return false }
        let context = QueryMatchContext(node: node, name: name, path: path, options: options, matchesPinyin: matchesPinyin)
        return expression.evaluate(context: context, content: nil, plainTermsTargetContent: false) == .match
    }

    func matchesContentCandidate(name: String, node: IndexedFileNode, path: String, options: SearchOptions, matchesPinyin: Bool = false) -> Bool {
        guard (!node.isDirectory || DocumentTextExtractor.isContentBearingDirectory(name: name)),
              node.isVisible(with: options) else { return false }
        let context = QueryMatchContext(node: node, name: name, path: path, options: options, matchesPinyin: matchesPinyin)
        let state = expression.evaluate(
            context: context,
            content: nil,
            plainTermsTargetContent: !hasExplicitContentFilter
        )
        return state != .noMatch
    }

    func matchesContent(_ content: String, node: ResolvedNode, options: SearchOptions) -> Bool {
        let context = QueryMatchContext(
            node: node.node,
            name: node.name,
            path: node.path,
            options: options,
            matchesPinyin: matchesPinyin
        )
        return expression.evaluate(
            context: context,
            content: content,
            plainTermsTargetContent: !hasExplicitContentFilter
        ) == .match
    }

    private func matchesBase(_ node: IndexedFileNode, path: String, options: SearchOptions) -> Bool {
        guard node.isVisible(with: options) else { return false }
        guard plan.filters.allSatisfy({ $0.matches(node: node, path: path, options: options) }) else { return false }
        guard !plan.excludedFilters.contains(where: { $0.matches(node: node, path: path, options: options) }) else { return false }
        let shortName = node.name.hasPrefix("/") ? (node.name as NSString).lastPathComponent : node.name
        for (index, matcher) in excludedMatchers.enumerated() {
            if matcher.matches(shortName) { return false }
            guard index < plan.excludedTerms.count else { continue }
            let term = plan.excludedTerms[index]
            if term.contains("/"),
               CompiledTextPredicate.pathTermMatches(term, path: path, caseSensitive: options.caseSensitive) {
                return false
            }
        }
        return true
    }
}

enum NodeKindFilter: Sendable, Equatable {
    case file
    case folder
}

enum SearchQueryFilter: Sendable, Equatable {
    case extensionIn(Set<String>)
    case kind(NodeKindFilter)
    case kindAndName(NodeKindFilter, String)
    case pathContains(String)
    case directChildren(String)
    case descendantOf(String)
    case withoutSubfolders(String)
    case size(SizePredicate)
    case modified(DatePredicate)
    case created(DatePredicate)
    case tagContains([String])

    var requiresCompleteMetadata: Bool {
        switch self {
        case .size, .modified, .created:
            return true
        case .extensionIn, .kind, .kindAndName, .pathContains,
             .directChildren, .descendantOf, .withoutSubfolders, .tagContains:
            return false
        }
    }

    func matches(node: IndexedFileNode, path: String, options: SearchOptions) -> Bool {
        switch self {
        case .extensionIn(let extensions):
            return !node.isDirectory && extensions.contains((path as NSString).pathExtension.lowercased())

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

        case .directChildren(let ancestor):
            return normalizedParent(of: path, caseSensitive: options.caseSensitive)
                == comparablePath(ancestor, caseSensitive: options.caseSensitive)

        case .descendantOf(let ancestor):
            let candidate = comparablePath(path, caseSensitive: options.caseSensitive)
            let root = comparablePath(ancestor, caseSensitive: options.caseSensitive)
            return candidate != root && SearchPath.hasNormalizedPrefix(candidate, of: root)

        case .withoutSubfolders(let ancestor):
            let candidate = comparablePath(path, caseSensitive: options.caseSensitive)
            let root = comparablePath(ancestor, caseSensitive: options.caseSensitive)
            if candidate == root { return true }
            return !node.isDirectory && normalizedParent(of: path, caseSensitive: options.caseSensitive) == root

        case .size(let predicate):
            return !node.isDirectory && predicate.matches(node.size)

        case .modified(let predicate):
            let modifiedDate = Date(timeIntervalSinceReferenceDate: node.modifiedTime)
            return predicate.matches(modifiedDate)

        case .created(let predicate):
            let createdDate = Date(timeIntervalSinceReferenceDate: node.creationTime)
            return predicate.matches(createdDate)

        case .tagContains(let needles):
            guard let rawTags = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.tagNamesKey]).tagNames else {
                return false
            }
            let tags = rawTags.map { String($0.split(separator: "\n", maxSplits: 1).first ?? Substring($0)) }
            return needles.contains { needle in
                tags.contains { tag in textContains(tag, needle, caseSensitive: options.caseSensitive) }
            }
        }
    }

    private func comparablePath(_ path: String, caseSensitive: Bool) -> String {
        let normalized = SearchPath.normalize(path)
        return caseSensitive ? normalized : normalized.lowercased()
    }

    private func normalizedParent(of path: String, caseSensitive: Bool) -> String {
        comparablePath((SearchPath.normalize(path) as NSString).deletingLastPathComponent, caseSensitive: caseSensitive)
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
    case notEqual
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
        case .comparison(.notEqual, let value):
            return size != value
        case .range(let lower, let upper):
            return size >= lower && size <= upper
        }
    }

    static func parse(_ raw: String) -> SizePredicate? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        if let keyword = parseKeyword(value) {
            return keyword
        }

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
            ("!=", .notEqual),
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

    private static func parseKeyword(_ value: String) -> SizePredicate? {
        switch value {
        case "empty":
            return SizePredicate(kind: .comparison(.equal, 0))
        case "tiny":
            return SizePredicate(kind: .range(1, 10 * 1024))
        case "small":
            return SizePredicate(kind: .range(10 * 1024 + 1, 100 * 1024))
        case "medium":
            return SizePredicate(kind: .range(100 * 1024 + 1, 1024 * 1024))
        case "large":
            return SizePredicate(kind: .range(1024 * 1024 + 1, 100 * 1024 * 1024))
        case "huge":
            return SizePredicate(kind: .range(100 * 1024 * 1024 + 1, 1024 * 1024 * 1024))
        case "gigantic", "giant":
            return SizePredicate(kind: .comparison(.greaterThanOrEqual, 1024 * 1024 * 1024 + 1))
        default:
            return nil
        }
    }

    private static func parseByteCount(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pattern = #"^([0-9]+(?:\.[0-9]+)?)(b|bytes?|k|kb|kib|kilobytes?|m|mb|mib|megabytes?|g|gb|gib|gigabytes?|t|tb|tib|terabytes?|p|pb|pib|petabytes?)?$"#
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
        case "p", "pb", "pib", "petabyte", "petabytes": 1024 * 1024 * 1024 * 1024 * 1024
        case "t", "tb", "tib", "terabyte", "terabytes": 1024 * 1024 * 1024 * 1024
        case "g", "gb", "gib", "gigabyte", "gigabytes": 1024 * 1024 * 1024
        case "m", "mb", "mib", "megabyte", "megabytes": 1024 * 1024
        case "k", "kb", "kib", "kilobyte", "kilobytes": 1024
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
        let calendar = Calendar.current
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
            return calendar.isDate(date, inSameDayAs: value)
        case .comparison(.notEqual, let value):
            return !calendar.isDate(date, inSameDayAs: value)
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
        case "thisweek":
            let interval = calendar.dateInterval(of: .weekOfYear, for: now)
            return interval.map { DatePredicate(kind: .range($0.start, $0.end)) }
        case "lastweek":
            guard let current = calendar.dateInterval(of: .weekOfYear, for: now),
                  let start = calendar.date(byAdding: .weekOfYear, value: -1, to: current.start) else { return nil }
            return DatePredicate(kind: .range(start, current.start))
        case "thismonth":
            let interval = calendar.dateInterval(of: .month, for: now)
            return interval.map { DatePredicate(kind: .range($0.start, $0.end)) }
        case "lastmonth":
            guard let current = calendar.dateInterval(of: .month, for: now),
                  let start = calendar.date(byAdding: .month, value: -1, to: current.start) else { return nil }
            return DatePredicate(kind: .range(start, current.start))
        case "thisyear":
            let interval = calendar.dateInterval(of: .year, for: now)
            return interval.map { DatePredicate(kind: .range($0.start, $0.end)) }
        case "lastyear":
            guard let current = calendar.dateInterval(of: .year, for: now),
                  let start = calendar.date(byAdding: .year, value: -1, to: current.start) else { return nil }
            return DatePredicate(kind: .range(start, current.start))
        case "pastweek":
            return DatePredicate(kind: .range(calendar.date(byAdding: .day, value: -7, to: now) ?? now, now))
        case "pastmonth":
            return DatePredicate(kind: .range(calendar.date(byAdding: .month, value: -1, to: now) ?? now, now))
        case "pastyear":
            return DatePredicate(kind: .range(calendar.date(byAdding: .year, value: -1, to: now) ?? now, now))
        default:
            break
        }

        if let separator = value.range(of: "..") {
            let lowerRaw = String(value[..<separator.lowerBound])
            let upperRaw = String(value[separator.upperBound...])
            guard let lower = parseDate(lowerRaw),
                  let upperDay = parseDate(upperRaw),
                  let upper = calendar.date(byAdding: .day, value: 1, to: upperDay),
                  lower < upper else { return nil }
            return DatePredicate(kind: .range(lower, upper))
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
            guard let date = parseDate(dateRaw) else { return nil }
            return DatePredicate(kind: .comparison(op, date))
        }

        guard let date = parseDate(value) else { return nil }
        return DatePredicate(kind: .comparison(.equal, date))
    }

    private static func parseDate(_ raw: String) -> Date? {
        for format in ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy.MM.dd", "dd-MM-yyyy", "MM/dd/yyyy"] {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
