import Foundation

/// Small deterministic arithmetic parser for launcher expressions.
enum QuickCalculator {
    static func evaluate(_ raw: String) -> String? {
        let expression = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty, expression.utf8.count <= 512 else { return nil }
        var parser = Parser(characters: Array(expression))
        guard let value = parser.parseExpression(), parser.isAtEnd, value.isFinite else { return nil }
        return String(format: "%.12g", value)
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        var isAtEnd: Bool { index >= characters.count }

        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let op = consumeOperator(["+", "-"]) {
                guard let rhs = parseTerm() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func parseTerm() -> Double? {
            guard var value = parseFactor() else { return nil }
            while let op = consumeOperator(["*", "/", "%"]) {
                guard let rhs = parseFactor(), (op != "/" && op != "%" || rhs != 0) else { return nil }
                switch op {
                case "*": value *= rhs
                case "/": value /= rhs
                default: value.formTruncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        mutating func parseFactor() -> Double? {
            skipWhitespace()
            if consume("+") { return parseFactor() }
            if consume("-") { return parseFactor().map(-) }
            if consume("(") {
                let value = parseExpression()
                guard consume(")") else { return nil }
                return value
            }
            let start = index
            while !isAtEnd && (characters[index].isNumber || characters[index] == ".") { index += 1 }
            guard index > start else { return nil }
            return Double(String(characters[start..<index]))
        }

        mutating func consume(_ character: Character) -> Bool {
            skipWhitespace()
            guard !isAtEnd, characters[index] == character else { return false }
            index += 1
            return true
        }

        mutating func consumeOperator(_ operators: [Character]) -> Character? {
            skipWhitespace()
            guard !isAtEnd, operators.contains(characters[index]) else { return nil }
            defer { index += 1 }
            return characters[index]
        }

        mutating func skipWhitespace() { while !isAtEnd && characters[index].isWhitespace { index += 1 } }
    }
}
