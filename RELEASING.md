# OpenFind release runbook

Public releases are created only from a semantic version tag such as `v1.1.0`.
The release workflow builds a macOS 14+ Universal app, signs every embedded
Sparkle component and the host app with one Developer ID identity, notarizes
and staples it, runs Gatekeeper and lossless-search checks, creates an
EdDSA-signed appcast with a one-day phased-rollout interval, and publishes the
ZIP, checksums, and appcast to GitHub Releases.

Required GitHub Actions secrets:

- `DEVELOPER_ID_APPLICATION_CERT_BASE64`: base64-encoded Developer ID
  Application `.p12`.
- `DEVELOPER_ID_APPLICATION_CERT_PASSWORD`: password for the `.p12`.
- `RELEASE_KEYCHAIN_PASSWORD`: ephemeral runner keychain password.
- `APP_STORE_CONNECT_API_KEY_BASE64`: base64-encoded notarization `.p8` key.
- `APP_STORE_CONNECT_KEY_ID` and `APP_STORE_CONNECT_ISSUER_ID`.
- `SPARKLE_PUBLIC_ED_KEY`: output of Sparkle `generate_keys` for `SUPublicEDKey`.
- `SPARKLE_PRIVATE_ED_KEY`: the matching exported private seed. Treat it as a
  release credential and never commit it.

Publish after the secrets are configured:

```bash
cd /path/to/OpenFind && git tag v1.1.0 && git push origin v1.1.0
```

The bundle identifier must remain `com.openfind.app` and the Developer ID team
must remain stable. After the first production-signed build and after every
certificate migration, verify that an in-place upgrade keeps Full Disk Access.
Do not compare this using a local self-signed build because macOS treats it as a
different code requirement.

Rollback is forward-only because Sparkle correctly refuses a lower build
number. Immediately convert a bad GitHub release to a draft so
`releases/latest` returns the previous appcast, then publish a corrected patch
with a higher version/build. Existing users who already installed the bad build
receive the corrected update; no user data or index format downgrade is needed.
The appcast retains three releases. Its generator is configured for up to five
deltas when prior release ZIPs are staged in the appcast directory; the current
single-release workflow intentionally publishes a full ZIP until that archive
retention step is added.
