import Foundation

extension ConfigurationSyncController {
    func export(to url: URL) async {
        guard !isBusy else { return }
        await performTransfer {
            let data = try self.transfer.snapshot().encoded()
            let previous = try await ConfigurationFile.read(url)
            try await ConfigurationFile.write(data, to: url, replacing: previous)
            self.message = L("Configuration Exported")
        }
    }

    func importConfiguration(from url: URL) async {
        guard !isBusy else { return }
        await performTransfer {
            guard let data = try await ConfigurationFile.read(url) else { throw ConfigurationError.missingFile }
            let archive = try (try? ConfigurationSyncDocument.decode(data).archive) ?? ConfigurationArchive.decode(data)
            try await self.transfer.apply(archive)
            self.message = L("Configuration Imported")
        }
    }

    func restore() async {
        guard !isBusy else { return }
        disconnect()
        await performTransfer {
            guard let data = try await ConfigurationFile.read(self.transfer.recoveryURL) else {
                throw ConfigurationError.missingFile
            }
            try await self.transfer.apply(ConfigurationArchive.decode(data), preservingRecovery: true)
            self.message = L("Configuration Restored")
        }
    }

    private func performTransfer(_ operation: () async throws -> Void) async {
        setBusy(true)
        defer { setBusy(false) }
        do { try await operation() }
        catch { message = error.localizedDescription }
    }
}
