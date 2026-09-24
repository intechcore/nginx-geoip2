# Contributing

Issues and pull requests are welcome.

## Build and test

```sh
make build                 # build the mainline branch
make build BRANCH=stable   # build the stable branch
make test                  # build and run all test suites
make coverage              # line coverage of the scripts
make lint                  # shellcheck + hadolint
```

CI runs for every pull request: ShellCheck, Hadolint, actionlint, zizmor, the branch version
check, the configuration contract and `trivy config`, the tests of both branches on amd64 and
arm64, the coverage run with the SonarCloud analysis, and a Trivy scan of both images.

## Pull requests

1. Branch from the default branch as `type/description`, for example `fix/empty-title`.
2. Keep one change per pull request. New behavior comes with tests; a bug fix adds a test that
   fails without it.
3. Write commit messages as [Conventional Commits](https://www.conventionalcommits.org/) without a
   scope: `feat: ...`, `fix: ...`, `docs: ...`, `refactor: ...`, `test: ...`, `build: ...`,
   `ci: ...`, `chore: ...`.
4. Sign your commits. The default branch accepts verified signatures only.
5. Add an entry under `## [Unreleased]` in `CHANGELOG.md`, written for users: the release notes
   quote it. Update the README when behavior or configuration changes.

Pull requests are squash-merged once all required checks are green.

## Releases

Releases are automatic when an input changes. The notes take the Unreleased entries added since
the previous release of the branch, see `.github/scripts/release-notes.sh`.

## Changelog

1. Keep one `## [Unreleased]` section on top, and add every entry there.
2. Do not cut per-release sections. The release notes pick the new entries by themselves.
3. Entries released by hand stay under `## History before automatic releases`.
