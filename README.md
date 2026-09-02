# Reusable GitHub Workflows

Shared GitHub Actions workflows for repositories in the organization.

GitHub only loads reusable workflows from `.github/workflows`, and each workflow
is exposed through `workflow_call`. Consumers should use the maintained `v1`
major tag so compatible fixes can be adopted without copying workflow logic.

## Repository access

If this repository is private, its Actions access policy must allow the intended
organization repositories to call its reusable workflows. Each caller must also
allow the actions used by these workflows under its repository or organization
Actions policy.

## PHP tests

```yaml
jobs:
  quality:
    uses: Ayup-Creative/workflows/.github/workflows/tests.yml@v1
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

## Automated releases

Release automation is deliberately split across two reusable workflows and two
small caller workflows:

1. The consumer schedules `weekly-release.yml` nightly. It compares `dev` with
   `main`, checks the exact development commit's `Release Gate`, and creates or
   reuses a protected promotion pull request.
2. The consumer calls `release.yml` on pushes to `main`. Release Please creates
   or updates its version and changelog pull request. Once that protected pull
   request merges, the next `main` run creates the SemVer tag and GitHub Release.

This event split avoids waiting inside a runner while checks, reviews, or a
merge queue are pending. Both workflows use the same per-repository and
release-branch concurrency group, and both are safe to rerun.

See [`examples/weekly-release.yml`](examples/weekly-release.yml) and
[`examples/release.yml`](examples/release.yml) for the default callers. The
nightly schedule is expressed in UTC and is offset from the start of the hour
to reduce GitHub Actions scheduling congestion.

### Authentication

Configure exactly one authentication mode using repository or organization
Actions secrets:

- `RELEASE_TOKEN`: a fine-grained personal access token with read/write
  Contents, Pull requests, Issues, and Workflows permissions for the consumer
  repository.
- `RELEASE_APP_CLIENT_ID` and `RELEASE_APP_PRIVATE_KEY`: credentials for a
  GitHub App installed on the consumer repository with the same permissions.

Workflows write access is needed because a promotion may contain changes under
`.github/workflows`. The App token requested by the release-only workflow omits
that permission because Release Please does not edit workflow files.

The workflows mint a short-lived, current-repository-only installation token
when App credentials are supplied. A pre-generated installation token should
not be stored because GitHub App installation tokens expire after one hour.
Environment secrets cannot be forwarded through `workflow_call`; use
repository or organization secrets so the example callers can use
`secrets: inherit`.

The built-in `GITHUB_TOKEN` is restricted to read-only branch comparison and
check/status inspection. All pull request, merge, tag, and release mutations
use the supplied PAT or App token so the resulting events can start the
consumer's CI and release workflows.

### Promotion inputs

| Input | Default | Purpose |
| --- | --- | --- |
| `development_branch` | `dev` | Branch containing release candidates. |
| `release_branch` | `main` | Protected branch containing released code. |
| `required_check` | `Release Gate` | Exact check-run or commit-status name required on the development SHA. |
| `required_check_kind` | `check-run` | Use `check-run` for GitHub Actions or `status` for a legacy commit status. |
| `required_check_app_id` | empty | Optionally require a check run from one trusted GitHub App. |
| `promotion_title` | `chore: promote dev to main` | Promotion pull request title. |
| `auto_merge` | `true` | Enable auto-merge without bypassing branch rules. |
| `merge_method` | `merge` | Use `merge`, `rebase`, or `queue`. |

The workflow compares branches before looking up the gate. When development is
not ahead, the run succeeds without loading release credentials or creating a
pull request. When promotion is needed, only one completed `success` result is
accepted; missing, pending, neutral, skipped, cancelled, stale, timed-out, or
failed results block the release. If more than one App reports the same check
name, configure `required_check_app_id` to remove the ambiguity.

The development SHA is checked again immediately before pull request work, and
auto-merge is requested with a matching-head-SHA guard. Set `auto_merge: false`
to create or reuse the pull request without merging it. Promotion intentionally
does not support squash because squashing the branch into the default `chore:`
promotion title would discard the Conventional Commits Release Please needs to
derive the correct version.

### Release inputs

| Input | Default | Purpose |
| --- | --- | --- |
| `release_branch` | `main` | Branch managed by Release Please. |
| `release_type` | `php` | Release Please strategy; override for Node, Python, Ruby, or another supported type. |
| `auto_merge` | `true` | Enable protected auto-merge for Release Please pull requests. |
| `merge_method` | `merge` | Use `merge`, `rebase`, `squash`, or `queue` for the release PR. |

Release Please derives patch, minor, and major versions from Conventional
Commits, maintains `CHANGELOG.md`, and creates release notes, tags, and GitHub
Releases. A `fix:` commit produces a patch, `feat:` produces a minor, and a
breaking-change marker produces a major under the default strategy. Commits
that do not request a release result in a successful no-change run.

### Consumer repository requirements

- Run the named release gate on direct pushes to the development branch and on
  promotion and Release Please pull requests targeting the release branch.
- Require that gate through branch protection or a ruleset on the release
  branch. The workflow's preflight gate prevents creating a promotion from an
  already-red development head; branch protection handles any later head
  update.
- Enable repository auto-merge when either reusable workflow uses its default
  `auto_merge: true` setting.
- Do not grant the PAT owner or GitHub App a branch-protection bypass. These
  workflows never use `--admin`, approve a pull request, force-push, or push
  directly to the release branch.
- Allow a history-preserving merge or rebase for promotion. For a merge queue,
  configure `merge_method: queue` and ensure the queue retains the Conventional
  Commit history.

The exact check name is the check run shown by GitHub, which can include caller
and reusable-job names. Override `required_check` when the consumer's final CI
job is not literally named `Release Gate`.

If a consumer changes `release_branch`, it must update both the caller's
`push.branches` filter and the `release_branch` input passed to both reusable
workflows. Event filters and schedules belong to caller workflows and cannot be
configured by `workflow_call` inputs.

Each run writes a job summary containing the compared branches and SHAs, ahead
and behind counts, gate result, promotion pull request, auto-merge disposition,
and any Release Please pull request, version, tag, or GitHub Release produced.

## Publishing compatible updates

Validate changes before moving the `v1` tag:

```shell
ruby tests/workflows_test.rb
actionlint .github/workflows/*.yml examples/*.yml
```

Breaking input or behavior changes require a new major tag. Do not move `v1`
until its commit is present on `main` and the validation workflow has passed.
Publish an immutable release tag first, then update the maintained `v1` alias
and verify that every reusable workflow exists at that exact ref.
