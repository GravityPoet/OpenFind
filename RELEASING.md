# OpenFind release runbook

Public releases are created only from a semantic version tag such as `v1.1.0`.
The release workflow builds a macOS 14+ Universal app, signs every embedded
Sparkle component and the host app with the pinned `OpenFind Customer Code
Signing` self-signed identity, runs lossless-search checks, creates an
EdDSA-signed appcast with a one-day phased-rollout interval, and publishes the
ZIP, checksums, and appcast to GitHub Releases. Customer builds fail closed if
the certificate fingerprint changes or ad-hoc signing is requested.

Required GitHub Actions secrets:

- `OPENFIND_CUSTOMER_CERT_BASE64`: base64-encoded OpenFind customer `.p12`.
- `OPENFIND_CUSTOMER_CERT_PASSWORD`: password for that `.p12`.
- `RELEASE_KEYCHAIN_PASSWORD`: ephemeral runner keychain password.
- `SPARKLE_PRIVATE_ED_KEY`: the matching exported private seed. Treat it as a
  release credential and never commit it.

Publish after the secrets are configured:

```bash
cd /path/to/OpenFind && git tag v1.1.0 && git push origin v1.1.0
```

The bundle identifier must remain `com.openfind.app` and the customer
certificate SHA-1 must remain
`3E146B469F41DEB31E45C28D0E9C512B3E5A41C1`. Build a customer archive locally
with `bash Scripts/build_customer_app.sh`. That entry point also pins the public
Sparkle EdDSA key and the production appcast URL, so local and CI customer builds
share one update trust root. Do not install that archive over a development-signed
local copy because macOS correctly treats the two identities as different code
requirements.

This no-fee distribution is intentionally not Apple-notarized. A newly
downloaded copy is therefore shown as coming from an unidentified developer;
the customer must approve its first launch in System Settings > Privacy &
Security > Open Anyway. Subsequent customer releases keep the same certificate
requirement, while Sparkle independently verifies update archives with the
pinned EdDSA key.

Rollback is forward-only because Sparkle correctly refuses a lower build
number. Immediately convert a bad GitHub release to a draft so
`releases/latest` returns the previous appcast, then publish a corrected patch
with a higher version/build. Existing users who already installed the bad build
receive the corrected update; no user data or index format downgrade is needed.
The appcast retains three releases. Its generator is configured for up to five
deltas when prior release ZIPs are staged in the appcast directory; the current
single-release workflow intentionally publishes a full ZIP until that archive
retention step is added.
