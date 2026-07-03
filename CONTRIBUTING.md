# Contributing

OpenFind uses an AGPL plus commercial licensing model. Contributions are welcome,
but external contributions must not be merged until the contributor license
agreement process below is complete.

## Contribution Requirements

By contributing to OpenFind, you must be able to confirm that:

- the contribution is your original work, or you have the right to submit it;
- the contribution does not include confidential information, trade secrets, or
  code copied from an incompatible license;
- the contribution can be released publicly under `AGPL-3.0-only`;
- the contribution can also be licensed by the project owner under separate
  commercial terms through the accepted contributor license agreement.

## Contributor License Agreement

Before a pull request or patch from an external contributor is merged, the
contributor must sign or otherwise formally accept
[CONTRIBUTOR_LICENSE_AGREEMENT.md](CONTRIBUTOR_LICENSE_AGREEMENT.md).

CLA and licensing contact: GitHub: @Newfund88

The CLA does not take copyright away from contributors. It grants the project
owner enough rights to keep distributing OpenFind under the AGPL and to offer
separate commercial licenses.

Maintainers should record CLA acceptance in the pull request, issue, or private
project records before merge. If CLA status is unclear, do not merge the
contribution.

## Development Verification

Use the repository's documented build command before submitting code changes:

```bash
xcrun --sdk macosx swift build
```

When changing behavior, add or update focused tests and run:

```bash
xcrun --sdk macosx swift test
```

## License and Brand Boundaries

Code contributions are handled through the AGPL and CLA model. The OpenFind name,
logo, and icon are separate brand assets and are governed by
[TRADEMARKS.md](TRADEMARKS.md).
