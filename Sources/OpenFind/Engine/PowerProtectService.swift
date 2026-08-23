import Foundation

enum PowerProtectInstallationStatus: Equatable, Sendable {
    case notInstalled
    case installed
    case invalid
    case unsupported
}

enum PowerProtectError: Error, Equatable, LocalizedError {
    case unsupported
    case authorizationRequired
    case authorizationCancelled
    case invalidUserName
    case existingRuleInvalid
    case commandFailed
    case outputTooLarge
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unsupported:
            L("Power Protect Unsupported")
        case .authorizationRequired:
            L("Power Protect Authorization Required")
        case .authorizationCancelled:
            L("Power Protect Authorization Cancelled")
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
              userName.caseInsensitiveCompare("ALL") != .orderedSame,
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
        data: Data?,
        attributes: [FileAttributeKey: Any],
        userName: String
    ) -> Bool {
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              (attributes[.groupOwnerAccountID] as? NSNumber)?.intValue == 0,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o440,
              let rule = try? PowerProtectRule(userName: userName),
              (attributes[.size] as? NSNumber)?.intValue == rule.contents.utf8.count
        else { return false }

        // A correct sudoers file is root:wheel 0440, so ordinary users usually
        // cannot read it. Validate exact bytes when available and otherwise
        // rely on immutable root-owned metadata; the first `sudo -n` command
        // remains the operational verification and never falls back to a
        // second authorization prompt.
        guard let data else { return true }
        return data.count <= 4_096 && rule.matches(data)
    }
}

@MainActor
protocol PowerProtectServicing: AnyObject {
    func status() -> PowerProtectInstallationStatus
    func install() async throws
    func uninstall() async throws
}

@MainActor
final class SudoersPowerProtectService: PowerProtectServicing {
    private nonisolated static let osascriptPath = "/usr/bin/osascript"
    private nonisolated static let maximumOutputBytes = 64 * 1_024
    private let fileManager: FileManager
    private let environment: [String: String]
    private let userNameProvider: @MainActor () -> String
    private var installTask: Task<Void, any Error>?

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
            guard PowerProtectFileValidator.isValid(
                    data: fileManager.contents(atPath: PowerProtectRule.targetPath),
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

    func install() async throws {
        try Task.checkCancellation()
        switch status() {
        case .installed:
            return
        case .notInstalled:
            break
        case .invalid:
            throw PowerProtectError.existingRuleInvalid
        case .unsupported:
            throw PowerProtectError.unsupported
        }
        if let installTask {
            try await installTask.value
            guard status() == .installed else { throw PowerProtectError.commandFailed }
            return
        }

        let rule = try PowerProtectRule(userName: userNameProvider())
        let task = Task { @MainActor [self] in
            try await runPrivileged(shellScript: installScript(rule: rule))
        }
        installTask = task
        defer { installTask = nil }
        try await task.value
        guard status() == .installed else { throw PowerProtectError.commandFailed }
    }

    func uninstall() async throws {
        try Task.checkCancellation()
        if let installTask { try await installTask.value }
        switch status() {
        case .notInstalled:
            return
        case .installed:
            break
        case .invalid:
            throw PowerProtectError.existingRuleInvalid
        case .unsupported:
            throw PowerProtectError.unsupported
        }
        let rule = try PowerProtectRule(userName: userNameProvider())
        try await runPrivileged(shellScript: uninstallScript(rule: rule))
        guard status() == .notInstalled else { throw PowerProtectError.commandFailed }
    }

    func installScript(rule: PowerProtectRule) -> String {
        let encodedRule = Data(rule.contents.utf8).base64EncodedString()
        return """
        set -eu
        target='\(PowerProtectRule.targetPath)'
        directory='/private/etc/sudoers.d'
        lock='/private/var/run/openfind-power-protect.lock'
        test -d "$directory"
        test ! -L "$directory"
        test "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$directory")" = 'root:wheel:755'
        exec 9>"$lock"
        /usr/sbin/chown root:wheel "$lock"
        /bin/chmod 0600 "$lock"
        /usr/bin/lockf -t 30 9
        temporary="$(/usr/bin/mktemp "$directory/.openfind-rule.XXXXXX")"
        installed=0
        installed_identity=''
        committed=0
        cleanup() {
          status=$?
          if test "$installed" -eq 1 && test "$committed" -ne 1 && test -e "$target" && { test -z "$temporary" || test ! -e "$temporary"; }; then
            current_identity="$(/usr/bin/stat -f '%d:%i' "$target" 2>/dev/null || true)"
            if test -z "$installed_identity" || test "$current_identity" = "$installed_identity"; then /bin/rm -f "$target"; fi
          fi
          if test -n "$temporary"; then /bin/rm -f "$temporary"; fi
          exit "$status"
        }
        trap cleanup EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        /bin/echo '\(encodedRule)' | /usr/bin/base64 -D > "$temporary"
        /usr/sbin/chown root:wheel "$temporary"
        /bin/chmod 0440 "$temporary"
        /usr/sbin/visudo -cf "$temporary" >/dev/null
        if test -e "$target"; then
          test ! -L "$target"
          test "$(/usr/bin/stat -f '%HT:%Su:%Sg:%Lp' "$target")" = 'Regular File:root:wheel:440'
          /usr/bin/cmp -s "$temporary" "$target"
          committed=1
          exit 0
        fi
        installed=1
        /bin/mv -n "$temporary" "$target"
        test ! -e "$temporary"
        temporary=''
        installed_identity="$(/usr/bin/stat -f '%d:%i' "$target")"
        if ! /usr/sbin/visudo -cf /etc/sudoers >/dev/null; then
          exit 1
        fi
        test "$(/usr/bin/stat -f '%HT:%Su:%Sg:%Lp' "$target")" = 'Regular File:root:wheel:440'
        committed=1
        """
    }

    func uninstallScript(rule: PowerProtectRule) -> String {
        let encodedRule = Data(rule.contents.utf8).base64EncodedString()
        return """
        set -eu
        target='\(PowerProtectRule.targetPath)'
        directory='/private/etc/sudoers.d'
        lock='/private/var/run/openfind-power-protect.lock'
        test -d "$directory"
        test ! -L "$directory"
        test "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$directory")" = 'root:wheel:755'
        exec 9>"$lock"
        /usr/sbin/chown root:wheel "$lock"
        /bin/chmod 0600 "$lock"
        /usr/bin/lockf -t 30 9
        test ! -L "$target"
        if test ! -e "$target"; then exit 0; fi
        test "$(/usr/bin/stat -f '%HT:%Su:%Sg:%Lp' "$target")" = 'Regular File:root:wheel:440'
        expected="$(/usr/bin/mktemp "$directory/.openfind-expected.XXXXXX")"
        backup="$(/usr/bin/mktemp "$directory/.openfind-remove-backup.XXXXXX")"
        removed=0
        committed=0
        cleanup() {
          status=$?
          if test "$removed" -eq 1 && test "$committed" -ne 1 && test ! -e "$target"; then
            if /bin/mv -n "$backup" "$target"; then backup=''; fi
          fi
          if test -n "$expected"; then /bin/rm -f "$expected"; fi
          if test -n "$backup" && { test "$removed" -eq 0 || test "$committed" -eq 1 || test -e "$target"; }; then
            /bin/rm -f "$backup"
          fi
          exit "$status"
        }
        trap cleanup EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        /bin/echo '\(encodedRule)' | /usr/bin/base64 -D > "$expected"
        /usr/bin/cmp -s "$expected" "$target"
        /bin/cp -p "$target" "$backup"
        removed=1
        /bin/rm -f "$target"
        if ! /usr/sbin/visudo -cf /etc/sudoers >/dev/null; then
          exit 1
        fi
        committed=1
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
            if message.contains("(-128)") || message.localizedCaseInsensitiveContains("canceled") {
                throw PowerProtectError.authorizationCancelled
            }
            if message.contains("OpenFind Power Protect")
                || message.contains("stat")
                || message.contains("cmp") {
                throw PowerProtectError.existingRuleInvalid
            }
            throw PowerProtectError.commandFailed
        }
    }
}
