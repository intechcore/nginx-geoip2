# Contributing

Issues and pull requests are welcome.

## Build and test

```sh
make build                 # build the mainline branch
make build BRANCH=stable   # build the stable branch
make test                  # build and run all test suites
make lint                  # shellcheck + hadolint
```

CI runs the same tests on amd64 and arm64 for every pull request, together with ShellCheck,
Hadolint, actionlint, zizmor, `trivy config` and a Trivy scan of the image.

## Pull requests

1. Keep one change per pull request, with tests where it changes behavior.
2. Write commit messages as [Conventional Commits](https://www.conventionalcommits.org/):
   `fix: ...`, `feat: ...`, `ci: ...`, `docs: ...`.
3. Sign your commits. The default branch accepts verified signatures only.
4. Update the README and the CHANGELOG with the change.

Pull requests are squash-merged once CI is green.
