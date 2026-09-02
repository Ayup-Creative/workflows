# Reusable GitHub Workflows

Shared GitHub Actions workflows for the private Aperture PHP repositories.

GitHub only loads reusable workflows from `.github/workflows`, and each workflow
is exposed through `workflow_call`. Consumers should use the maintained `v1`
major tag so compatible fixes can be adopted without copying workflow logic.

## Repository access

This repository is private. Its Actions access setting must remain **Accessible
from repositories owned by `mykemeynell`**. GitHub only permits private caller
repositories owned by the same user to use these workflows.

## PHP tests

```yaml
jobs:
  quality:
    uses: mykemeynell/workflows/.github/workflows/tests.yml@v1
    with:
      php_versions: '["8.3","8.4","8.5"]'
      phpstan_php_version: '8.4'
      composer_repositories: >-
        {"vendor-package":"https://github.com/example/vendor-package.git"}
    secrets:
      composer_token: ${{ secrets.COMPOSER_TOKEN }}
```

The reusable test workflow accepts these inputs:

| Input | Default | Purpose |
| --- | --- | --- |
| `php_versions` | `["8.3","8.4","8.5"]` | JSON array used by the Pest matrix. |
| `phpstan_php_version` | `8.4` | PHP version used for PHPStan. |
| `lowest_php_version` | empty | PHP version used with `--prefer-lowest`; an empty value selects the highest version in `php_versions`. |
| `composer_repositories` | `{}` | JSON object mapping generic repository names to private VCS URLs. |

Versions must be unique numeric `major.minor` or `major.minor.patch` strings.
An explicit `lowest_php_version` does not need to appear in `php_versions`.

The optional `composer_token` secret authenticates Composer with GitHub before
private VCS repositories are added. Callers without private dependencies omit
both settings. Repository names and URLs are supplied entirely by the caller;
the shared workflow contains no project-specific package list.

For private GitHub repositories, use a fine-grained token with read-only
`Contents` access to the required dependency repositories. Store it as an
Actions repository or organization secret in the caller; never place the token
inside the repository JSON or commit Composer authentication files.

The workflow runs Composer validation, Pint, and Pest with 100% coverage for
each test-matrix version. PHPStan and lowest-dependency testing run once on
their configured versions. The final `Quality gate` job fails unless every
required job succeeds.

See [`examples/tests.yml`](examples/tests.yml) for a caller that runs on pushes
and pull requests targeting `main` or `dev`, while also exposing
`workflow_call` so release workflows reuse the same PHP configuration.

## Release Please

Release Please is deliberately split into two stages:

1. Manually run the consumer's `Release` workflow from `main`. It reruns the
   repository's quality workflow before opening or updating a release PR.
2. Merge the generated release PR. The consumer's `Finalize Release` workflow
   reruns quality against merged `main`, creates the tag and GitHub Release,
   and then deletes the merged release-please branch.

Ordinary pushes and merged feature branches never invoke Release Please. The
shared workflow fails if called from a ref other than its configured target
branch, and concurrent release runs for the same repository and branch are
serialized.

The workflow uses the built-in `GITHUB_TOKEN`. A release-please-created pull
request can display an **Approve workflows to run** banner before its CI starts;
approve that run manually. No PAT or automated pull-request approval is used.

If finalization fails before a release is created, fix `main` and manually run
`Release` again. Release Please is safe to rerun and will finalize the merged
release PR once quality passes. A branch left behind by a failed automatic
cleanup can be removed manually after confirming that the GitHub Release exists.

See [`examples/release.yml`](examples/release.yml) and
[`examples/finalize-release.yml`](examples/finalize-release.yml) for complete
callers.

## Publishing compatible updates

Validate changes before moving the `v1` tag:

```shell
ruby tests/workflows_test.rb
actionlint .github/workflows/*.yml examples/*.yml
```

Breaking input or behavior changes require a new major tag. Do not move `v1`
until its commit is present on `main` and the validation workflow has passed.
