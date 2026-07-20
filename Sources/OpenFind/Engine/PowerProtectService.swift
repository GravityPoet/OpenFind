import Foundation

enum PowerProtectInstallationStatus: Equatable, Sendable {
    case notInstalled
    case installed
    case invalid
    case unsupported
}

enum PowerProtectError: Error, Equatable, LocalizedError {
    case unsupported
    case invalidUserName
    case existingRuleInvalid
    case commandFailed
    case outputTooLarge
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unsupported:
            L("Power Protect Unsupported")
        case .invalidUserName:
            L("Power Protect User Invalid")
        case .existingRuleInvalid:
            L("Power Protect Existing Rule Invalid")
        case .commandFailed:
            L("Power Protect Command Failed")
        case .outputTooLarge:
            L("Power Protect Output Too Large")
        case .timedOut:
            L("Power Protect Timed Out")
        }
    }
}

struct PowerProtectRule: Equatable, Sendable {
    static let targetPath = "/private/etc/sudoers.d/openfind-power-protect"
    static let marker = "# OpenFind Power Protect v1"
    let userName: String

    init(userName: String) throws {
        let scalars = userName.unicodeScalars
        guard !userName.isEmpty,
              userName.utf8.count <= 64,
              let first = scalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first),
              scalars.allSatisfy({
                  CharacterSet.alphanumerics
                      .union(CharacterSet(charactersIn: "_.-"))
                      .contains($0)
              }) else {
            throw PowerProtectError.invalidUserName
        }
        self.userName = userName
    }

    var contents: String {
        """
        \(Self.marker)
        \(userName) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0

        """
    }

    func matches(_ data: Data) -> Bool {
        data == Data(contents.utf8)
    }
}

enum PowerProtectFileValidator {
    static func isValid(
        data: Data,
        attributes: [FileAttributeKey: Any],
        userName: String
    ) -> Bool {
        guard data.count <= 4_096,
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              (attributes[.groupOwnerAccountID] as? NSNumber)?.intValue == 0,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o440,
              let rule = try? PowerProtectRule(userName: userName) else { return false }
        return rule.matches(data)
    }
}

@MainActor
protocol PowerProtectServicing: AnyObject {
    func status() -> PowerProtectInstallationStatus
    func install(for userName: String) async throws
    func uninstall(for userName: String) async throws
}

@MainActor
final class SudoersPowerProtectService: PowerProtectServicing {
    private nonisolated static let osascriptPath = "/usr/bin/osascript"
    private nonisolated static let maximumOutputBytes = 64 * 1_024
    private let fileManager: FileManager
    private let environment: [String: String]
    private let userNameProvider: @MainActor () -> String

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userNameProvider: @escaping @MainActor () -> String = { NSUserName() }
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.userNameProvider = userNameProvider
    }

    func status() -> PowerProtectInstallationStatus {
        guard environment["APP_SANDBOX_CONTAINER_ID"] == nil else { return .unsupported }
        guard fileManager.fileExists(atPath: PowerProtectRule.targetPath) else {
            return .notInstalled
        }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: PowerProtectRule.targetPath)
            guard let data = fileManager.contents(atPath: PowerProtectRule.targetPath),
                  PowerProtectFileValidator.isValid(
                    data: data,
                    attributes: attributes,
                    userName: userNameProvider()
                  ) else {
                return .invalid
            }
            return .installed
        } catch {
            return .invalid
        }
    }

    func install(for userName: String) async throws {
        guard status() != .unsupported else { throw PowerProtectError.unsupported }
        let rule = try PowerProtectRule(userName: userName)
        try await runPrivileged(shellScript: installScript(rule: rule))
        guard status() == .installed else { throw PowerProtectError.commandFailed }
    }

    func uninstall(for userName: String) async throws {
        guard status() != .unsupported else { throw PowerProtectError.unsupported }
        let rule = try PowerProtectRule(userName: userName)
        guard status() != .notInstalled else { return }
        try await runPrivileged(shellScript: uninstallScript(rule: rule))
        guard status() == .notInstalled else { throw PowerProtectError.commandFailed }
    }

    func installScript(rule: PowerProtectRule) -> String {
        let encodedRule = Data(rule.contents.utf8).base64EncodedString()
        return """
        set -eu
        target='\(PowerProtectRule.targetPath)'
        directory='/private/etc/sudoers.d'
        test -d "$directory"
        test ! -L "$target"
        if test -e "$target"; then
          test "$(/usr/bin/head -n 1 "$target")" = '\(PowerProtectRule.marker)'
          test "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$target")" = 'root:wheel:440'
        fi
        temporary="$(/usr/bin/mktemp "$directory/.openfind-rule.XXXXXX")"
        backup=''
        cleanup() {
          /bin/rm -f "$temporary"
          if test -n "$backup"; then /bin/rm -f "$backup"; fi
        }
        trap cleanup EXIT HUP INT TERM
        /bin/echo '\(encodedRule)' | /usr/bin/base64 -D > "$temporary"
        /usr/sbin/chown root:wheel "$temporary"
        /bin/chmod 0440 "$temporary"
        /usr/sbin/visudo -cf "$temporary" >/dev/null
        if test -e "$target"; then
          backup="$(/usr/bin/mktemp "$directory/.openfind-backup.XXXXXX")"
          /bin/cp -p "$target" "$backup"
        fi
        /bin/mv -f "$temporary" "$target"
        temporary=''
        if ! /usr/sbin/visudo -cf /etc/sudoers >/dev/null; then
          if test -n "$backup"; then
            /bin/mv -f "$backup" "$target"
            backup=''
          else
            /bin/rm -f "$target"
          fi
          exit 1
        fi
        /bin/chmod 0440 "$target"
        /usr/sbin/chown root:wheel "$target"
        """
    }

    func uninstallScript(rule: PowerProtectRule) -> String {
        let encodedRule = Data(rule.contents.utf8).base64EncodedString()
        return """
        set -eu
        target='\(PowerProtectRule.targetPath)'
        directory='/private/etc/sudoers.d'
        test ! -L "$target"
        if test ! -e "$target"; then exit 0; fi
        test "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$target")" = 'root:wheel:440'
        expected="$(/usr/bin/mktemp "$directory/.openfind-expected.XXXXXX")"
        backup="$(/usr/bin/mktemp "$directory/.openfind-remove-backup.XXXXXX")"
        cleanup() { /bin/rm -f "$expected" "$backup"; }
        trap cleanup EXIT HUP INT TERM
        /bin/echo '\(encodedRule)' | /usr/bin/base64 -D > "$expected"
        /usr/bin/cmp -s "$expected" "$target"
        /bin/cp -p "$target" "$backup"
        /bin/rm -f "$target"
        if ! /usr/sbin/visudo -cf /etc/sudoers >/dev/null; then
          /bin/mv -f "$backup" "$target"
          backup=''
          exit 1
        fi
        """
    }

    private func runPrivileged(shellScript: String) async throws {
        let encodedScript = Data(shellScript.utf8).base64EncodedString()
        let command = "/bin/echo '\(encodedScript)' | /usr/bin/base64 -D | /bin/sh"
        let appleScript = "do shell script \"\(command)\" with administrator privileges"
        let result: BoundedProcessResult
        do {
            result = try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: Self.osascriptPath),
                arguments: ["-e", appleScript],
                timeout: 300,
                outputLimit: Self.maximumOutputBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PowerProtectError.commandFailed
        }
        guard !result.timedOut else { throw PowerProtectError.timedOut }
        guard !result.outputExceededLimit else { throw PowerProtectError.outputTooLarge }
        guard result.terminationStatus == 0 else {
            let message = String(decoding: result.output, as: UTF8.self)
            if message.contains("OpenFind Power Protect")
                || message.contains("stat")
                || message.contains("cmp") {
                throw PowerProtectError.existingRuleInvalid
            }
            throw PowerProtectError.commandFailed
        }
    }
}
