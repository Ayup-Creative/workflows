# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'open3'
require 'pathname'
require 'tempfile'
require 'tmpdir'
require 'yaml'

class WorkflowsTest < Minitest::Test
  ROOT = Pathname(__dir__).join('..').expand_path
  TESTS_WORKFLOW_PATH = ROOT.join('.github/workflows/tests.yml')
  RELEASE_WORKFLOW_PATH = ROOT.join('.github/workflows/release.yml')
  WEEKLY_RELEASE_WORKFLOW_PATH = ROOT.join('.github/workflows/weekly-release.yml')
  TESTS_CALLER_PATH = ROOT.join('examples/tests.yml')
  RELEASE_CALLER_PATH = ROOT.join('examples/release.yml')
  WEEKLY_RELEASE_CALLER_PATH = ROOT.join('examples/weekly-release.yml')
  FINALIZE_CALLER_PATH = ROOT.join('examples/finalize-release.yml')

  def test_reusable_workflows_live_in_the_supported_directory
    assert File.exist?(TESTS_WORKFLOW_PATH), "Expected #{TESTS_WORKFLOW_PATH} to exist"
    assert File.exist?(RELEASE_WORKFLOW_PATH), "Expected #{RELEASE_WORKFLOW_PATH} to exist"
    assert File.exist?(WEEKLY_RELEASE_WORKFLOW_PATH), "Expected #{WEEKLY_RELEASE_WORKFLOW_PATH} to exist"
    refute File.exist?(ROOT.join('.github/tests.yml'))
    refute File.exist?(ROOT.join('.github/release.yml'))
    refute File.exist?(ROOT.join('.github/weekly-release.yml'))
  end

  def test_tests_workflow_exposes_the_expected_php_inputs
    inputs = workflow_call_inputs(tests_workflow)

    assert_equal 'string', inputs.dig('php_versions', 'type')
    assert_equal '["8.3","8.4","8.5"]', inputs.dig('php_versions', 'default')
    assert_equal '8.4', inputs.dig('phpstan_php_version', 'default')
    assert_equal '', inputs.dig('lowest_php_version', 'default')
  end

  def test_tests_workflow_exposes_optional_composer_repository_configuration
    inputs = workflow_call_inputs(tests_workflow)
    secrets = tests_workflow.dig('on', 'workflow_call', 'secrets')

    assert_equal 'string', inputs.dig('composer_repositories', 'type')
    assert_equal '{}', inputs.dig('composer_repositories', 'default')
    assert_equal false, secrets.dig('composer_token', 'required')
  end

  def test_composer_repositories_are_normalized_before_quality_jobs_start
    repositories = {
      'framework' => 'https://github.com/example/framework.git',
      'database' => 'https://github.com/example/database.git'
    }
    result = resolve_composer_repositories(JSON.generate(repositories))

    assert_predicate result, :success?, result.stderr
    assert_equal repositories, JSON.parse(result.outputs.fetch('composer_repositories'))
  end

  def test_invalid_composer_repository_configuration_fails_closed
    invalid_inputs = [
      '[]',
      '{"invalid name":"https://github.com/example/package.git"}',
      '{"package":false}',
      '{"package":""}',
      '{"package":"--no-interaction"}',
      '{"package":"https://example.com/package.git\\nunsafe"}'
    ]

    invalid_inputs.each do |repositories|
      result = resolve_composer_repositories(repositories)

      refute_predicate result, :success?, "Expected #{repositories.inspect} to fail"
      assert_includes result.stderr, 'Invalid Composer repository configuration'
    end
  end

  def test_composer_setup_configures_generic_vcs_repositories_and_optional_authentication
    script = composer_setup_script

    Dir.mktmpdir('composer-setup') do |directory|
      calls = File.join(directory, 'calls')
      composer = File.join(directory, 'composer')
      File.write(composer, "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"$COMPOSER_CALLS\"\n")
      File.chmod(0o755, composer)

      repositories = JSON.generate(
        'framework' => 'https://github.com/example/framework.git',
        'database' => 'https://github.com/example/database.git'
      )
      _stdout, stderr, status = Open3.capture3(
        {
          'PATH' => "#{directory}:#{ENV.fetch('PATH')}",
          'COMPOSER_CALLS' => calls,
          'COMPOSER_REPOSITORIES' => repositories,
          'COMPOSER_TOKEN' => 'private-token'
        },
        'bash',
        stdin_data: script
      )

      assert_predicate status, :success?, stderr
      assert_equal [
        'config --global --auth github-oauth.github.com private-token',
        'repo add --global framework vcs https://github.com/example/framework.git',
        'repo add --global database vcs https://github.com/example/database.git'
      ], File.readlines(calls, chomp: true)
    end
  end

  def test_composer_setup_is_a_no_op_for_projects_without_private_repositories
    Dir.mktmpdir('composer-setup') do |directory|
      calls = File.join(directory, 'calls')
      composer = File.join(directory, 'composer')
      File.write(composer, "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"$COMPOSER_CALLS\"\n")
      File.chmod(0o755, composer)

      _stdout, stderr, status = Open3.capture3(
        {
          'PATH' => "#{directory}:#{ENV.fetch('PATH')}",
          'COMPOSER_CALLS' => calls,
          'COMPOSER_REPOSITORIES' => '{}',
          'COMPOSER_TOKEN' => ''
        },
        'bash',
        stdin_data: composer_setup_script
      )

      assert_predicate status, :success?, stderr
      refute File.exist?(calls)
    end
  end

  def test_tests_workflow_routes_resolved_versions_to_each_quality_job
    jobs = tests_workflow.fetch('jobs')

    assert_equal '${{ fromJSON(needs.configuration.outputs.php_versions) }}',
                 jobs.dig('tests', 'strategy', 'matrix', 'php')
    assert_equal '${{ needs.configuration.outputs.phpstan_php_version }}',
                 setup_php_version(jobs.fetch('analysis'))
    assert_equal '${{ needs.configuration.outputs.lowest_php_version }}',
                 setup_php_version(jobs.fetch('lowest'))
    assert_equal %w[configuration tests analysis lowest].sort,
                 Array(jobs.dig('quality', 'needs')).sort
    assert_equal '${{ always() }}', jobs.dig('quality', 'if')
  end

  def test_default_lowest_version_is_the_highest_version_in_an_unordered_matrix
    result = resolve_versions('["8.5","8.3","8.4"]')

    assert_predicate result, :success?, result.stderr
    assert_equal ['8.5', '8.3', '8.4'], JSON.parse(result.outputs.fetch('php_versions'))
    assert_equal '8.4', result.outputs.fetch('phpstan_php_version')
    assert_equal '8.5', result.outputs.fetch('lowest_php_version')
  end

  def test_explicit_lowest_version_overrides_the_matrix_default
    result = resolve_versions('["8.3","8.4"]', lowest_php_version: '8.2')

    assert_predicate result, :success?, result.stderr
    assert_equal '8.2', result.outputs.fetch('lowest_php_version')
  end

  def test_highest_version_is_compared_numerically
    result = resolve_versions('["8.9","8.10","8.4.12"]')

    assert_predicate result, :success?, result.stderr
    assert_equal '8.10', result.outputs.fetch('lowest_php_version')
  end

  def test_invalid_php_version_configuration_fails_closed
    invalid_inputs = {
      'not-json' => '',
      '[]' => '',
      '["8.4","8.4"]' => '',
      '[8.3,"8.4"]' => '',
      '["nightly"]' => '',
      '["8.3"]' => 'nightly'
    }

    invalid_inputs.each do |php_versions, lowest_php_version|
      result = resolve_versions(php_versions, lowest_php_version: lowest_php_version)

      refute_predicate result, :success?, "Expected #{php_versions.inspect} to fail"
      assert_includes result.stderr, 'Invalid PHP version configuration'
    end
  end

  def test_invalid_phpstan_version_fails_closed
    result = resolve_versions('["8.3"]', phpstan_php_version: 'nightly')

    refute_predicate result, :success?
    assert_includes result.stderr, 'Invalid PHP version configuration'
  end

end

class PromotionWorkflowsTest < Minitest::Test

  def test_weekly_release_workflow_exposes_safe_promotion_defaults
    workflow = weekly_release_workflow
    inputs = workflow_call_inputs(workflow)
    secrets = workflow.dig('on', 'workflow_call', 'secrets')

    assert_equal ['workflow_call'], workflow.fetch('on').keys
    assert_equal 'dev', inputs.dig('development_branch', 'default')
    assert_equal 'main', inputs.dig('release_branch', 'default')
    assert_equal 'Release Gate', inputs.dig('required_check', 'default')
    assert_equal 'check-run', inputs.dig('required_check_kind', 'default')
    assert_equal '', inputs.dig('required_check_app_id', 'default')
    assert_equal 'chore: promote dev to main', inputs.dig('promotion_title', 'default')
    assert_equal true, inputs.dig('auto_merge', 'default')
    assert_equal 'merge', inputs.dig('merge_method', 'default')
    assert_equal false, secrets.dig('RELEASE_TOKEN', 'required')
    assert_equal false, secrets.dig('RELEASE_APP_CLIENT_ID', 'required')
    assert_equal false, secrets.dig('RELEASE_APP_PRIVATE_KEY', 'required')
    app_token = first_job(workflow).fetch('steps').find { |step| step['id'] == 'app-token' }
    assert_equal 'write', app_token.dig('with', 'permission-workflows')
  end

  def test_weekly_release_compares_before_gate_and_never_bypasses_protection
    steps = weekly_release_workflow.dig('jobs', 'promotion', 'steps')
    names = steps.map { |step| step.fetch('name') }
    comparison = steps.find { |step| step['name'] == 'Compare release branches' }
    gate = steps.find { |step| step['name'] == 'Evaluate release gate' }
    auto_merge = steps.find { |step| step['name'] == 'Configure promotion auto-merge' }
    scripts = steps.map { |step| step['run'] }.compact.join("\n")

    assert_operator names.index('Compare release branches'), :<, names.index('Evaluate release gate')
    assert_includes comparison.fetch('run'), 'RELEASE_REQUIRED=false'
    assert_equal "${{ steps.comparison.outputs.release_required == 'true' }}", gate.fetch('if')
    assert_includes auto_merge.fetch('run'), '--match-head-commit'
    assert_includes auto_merge.fetch('run'), '--auto'
    assert_includes auto_merge.fetch('run'), "auto_merge_state=disabled"
    assert_operator auto_merge.fetch('run').index("AUTO_MERGE\" != 'true'"),
                    :<,
                    auto_merge.fetch('run').index('gh pr merge')
    refute_includes scripts, '--admin'
    refute_match(/git\s+push/, scripts)
  end

  def test_weekly_release_uses_read_only_builtin_token_and_shared_concurrency
    permissions = weekly_release_workflow.fetch('permissions')

    assert_equal 'read', permissions.fetch('contents')
    assert_equal 'read', permissions.fetch('checks')
    assert_equal 'read', permissions.fetch('statuses')
    refute permissions.value?('write')
    assert_equal 'release-${{ github.repository }}-${{ inputs.release_branch }}',
                 weekly_release_workflow.dig('concurrency', 'group')
    assert_equal false, weekly_release_workflow.dig('concurrency', 'cancel-in-progress')
  end

  def test_weekly_release_reports_all_gate_and_promotion_details
    summary = weekly_release_workflow.dig('jobs', 'promotion', 'steps').find do |step|
      step['name'] == 'Write release summary'
    end
    script = summary.fetch('run')

    assert_equal '${{ always() }}', summary.fetch('if')
    %w[development_sha release_sha ahead behind comparison_status gate_status gate_conclusion
       promotion_pr_url auto_merge_state].each do |value|
      assert_includes summary.fetch('env').values.join(' '), "outputs.#{value}"
    end
    assert_includes script, 'GITHUB_STEP_SUMMARY'
    assert_predicate script, :ascii_only?
  end

  def test_release_authentication_accepts_one_mode_and_rejects_ambiguous_configuration
    scripts = [weekly_release_workflow, release_workflow].map do |workflow|
      first_job(workflow).fetch('steps').find do |step|
        step['name'] == 'Validate release authentication'
      end.fetch('run')
    end

    assert_equal 1, scripts.uniq.length
    script = scripts.first

    token = run_shell_script(
      script,
      'RELEASE_TOKEN' => 'pat',
      'RELEASE_APP_CLIENT_ID' => '',
      'RELEASE_APP_PRIVATE_KEY' => ''
    )
    app = run_shell_script(
      script,
      'RELEASE_TOKEN' => '',
      'RELEASE_APP_CLIENT_ID' => 'client-id',
      'RELEASE_APP_PRIVATE_KEY' => 'private-key'
    )

    assert_predicate token, :success?, token.stderr
    assert_equal 'token', token.outputs.fetch('mode')
    assert_predicate app, :success?, app.stderr
    assert_equal 'app', app.outputs.fetch('mode')

    [
      ['', '', ''],
      ['', 'client-id', ''],
      ['', '', 'private-key'],
      ['pat', 'client-id', 'private-key']
    ].each do |release_token, client_id, private_key|
      result = run_shell_script(
        script,
        'RELEASE_TOKEN' => release_token,
        'RELEASE_APP_CLIENT_ID' => client_id,
        'RELEASE_APP_PRIVATE_KEY' => private_key
      )

      refute_predicate result, :success?
    end
  end

  def test_check_run_gate_accepts_only_one_completed_success
    script = first_job(weekly_release_workflow).fetch('steps').find do |step|
      step['name'] == 'Evaluate release gate'
    end.fetch('run')
    scenarios = {
      ['completed', 'success'] => 'true',
      ['in_progress', nil] => 'false',
      ['completed', 'failure'] => 'false',
      ['completed', 'cancelled'] => 'false',
      ['completed', 'skipped'] => 'false'
    }

    scenarios.each do |(status, conclusion), expected_green|
      response = {
        'check_runs' => [
          {
            'id' => 7,
            'status' => status,
            'conclusion' => conclusion,
            'started_at' => '2026-09-03T01:00:00Z',
            'completed_at' => status == 'completed' ? '2026-09-03T01:01:00Z' : nil,
            'details_url' => 'https://github.example/check/7',
            'app' => { 'id' => 15368 }
          }
        ]
      }
      result = run_shell_script_with_gh(
        script,
        "#!/usr/bin/env bash\nprintf '%s\\n' \"$MOCK_GH_RESPONSE\"\n",
        gate_environment.merge('MOCK_GH_RESPONSE' => JSON.generate(response))
      )

      assert_predicate result, :success?, result.stderr
      assert_equal expected_green, result.outputs.fetch('gate_green')
      assert_equal status, result.outputs.fetch('gate_status')
      assert_equal(conclusion || 'pending', result.outputs.fetch('gate_conclusion'))
    end
  end

  def test_check_run_gate_fails_closed_for_missing_or_ambiguous_results
    script = first_job(weekly_release_workflow).fetch('steps').find do |step|
      step['name'] == 'Evaluate release gate'
    end.fetch('run')
    responses = [
      { 'check_runs' => [] },
      {
        'check_runs' => [
          successful_check_run(1, 100),
          successful_check_run(2, 200)
        ]
      }
    ]

    responses.each do |response|
      result = run_shell_script_with_gh(
        script,
        "#!/usr/bin/env bash\nprintf '%s\\n' \"$MOCK_GH_RESPONSE\"\n",
        gate_environment.merge('MOCK_GH_RESPONSE' => JSON.generate(response))
      )

      assert_predicate result, :success?, result.stderr
      assert_equal 'false', result.outputs.fetch('gate_green')
    end
  end

  def test_check_run_gate_uses_latest_rerun_from_the_same_app
    script = first_job(weekly_release_workflow).fetch('steps').find do |step|
      step['name'] == 'Evaluate release gate'
    end.fetch('run')
    response = {
      'check_runs' => [
        successful_check_run(1, 15368).merge(
          'status' => 'completed',
          'conclusion' => 'failure',
          'completed_at' => '2026-09-03T01:01:00Z'
        ),
        successful_check_run(2, 15368).merge(
          'completed_at' => '2026-09-03T01:05:00Z'
        )
      ]
    }
    result = run_shell_script_with_gh(
      script,
      "#!/usr/bin/env bash\nprintf '%s\\n' \"$MOCK_GH_RESPONSE\"\n",
      gate_environment.merge('MOCK_GH_RESPONSE' => JSON.generate(response))
    )

    assert_predicate result, :success?, result.stderr
    assert_equal 'true', result.outputs.fetch('gate_green')
    assert_equal 'success', result.outputs.fetch('gate_conclusion')
  end

  def test_legacy_status_gate_uses_the_latest_exact_context
    script = first_job(weekly_release_workflow).fetch('steps').find do |step|
      step['name'] == 'Evaluate release gate'
    end.fetch('run')
    response = {
      'statuses' => [
        {
          'id' => 1,
          'context' => 'Release Gate',
          'state' => 'failure',
          'created_at' => '2026-09-03T01:00:00Z'
        },
        {
          'id' => 2,
          'context' => 'Other Check',
          'state' => 'success',
          'created_at' => '2026-09-03T01:02:00Z'
        },
        {
          'id' => 3,
          'context' => 'Release Gate',
          'state' => 'success',
          'created_at' => '2026-09-03T01:03:00Z',
          'target_url' => 'https://github.example/status/3'
        }
      ]
    }
    result = run_shell_script_with_gh(
      script,
      "#!/usr/bin/env bash\nprintf '%s\\n' \"$MOCK_GH_RESPONSE\"\n",
      gate_environment.merge(
        'REQUIRED_CHECK_KIND' => 'status',
        'MOCK_GH_RESPONSE' => JSON.generate(response)
      )
    )

    assert_predicate result, :success?, result.stderr
    assert_equal 'true', result.outputs.fetch('gate_green')
    assert_equal 'success', result.outputs.fetch('gate_status')
    assert_equal 'https://github.example/status/3', result.outputs.fetch('gate_details_url')
  end

  def test_disabled_auto_merge_never_calls_github_cli
    weekly_step = first_job(weekly_release_workflow).fetch('steps').find do |step|
      step['name'] == 'Configure promotion auto-merge'
    end
    release_step = first_job(release_workflow).fetch('steps').find do |step|
      step['name'] == 'Configure release auto-merge'
    end

    Dir.mktmpdir('merge-calls') do |directory|
      calls = File.join(directory, 'calls')
      gh = "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"$MOCK_GH_CALLS\"\nexit 99\n"
      weekly = run_shell_script_with_gh(
        weekly_step.fetch('run'),
        gh,
        'MOCK_GH_CALLS' => calls,
        'AUTO_MERGE' => 'false',
        'MERGE_METHOD' => 'merge',
        'PR_NUMBER' => '12',
        'REPOSITORY' => 'example/project',
        'EXPECTED_DEVELOPMENT_SHA' => 'abc123'
      )
      release = run_shell_script_with_gh(
        release_step.fetch('run'),
        gh,
        'MOCK_GH_CALLS' => calls,
        'AUTO_MERGE' => 'false',
        'MERGE_METHOD' => 'merge',
        'PULL_REQUESTS' => '[{"number":34}]',
        'REPOSITORY' => 'example/project'
      )

      assert_predicate weekly, :success?, weekly.stderr
      assert_equal 'disabled', weekly.outputs.fetch('auto_merge_state')
      assert_predicate release, :success?, release.stderr
      assert_equal 'disabled', release.outputs.fetch('auto_merge_state')
      refute File.exist?(calls)
    end
  end

  def test_branch_comparison_marks_an_unchanged_development_branch_as_a_no_op
    script = first_job(weekly_release_workflow).fetch('steps').find do |step|
      step['name'] == 'Compare release branches'
    end.fetch('run')
    gh = <<~'BASH'
      #!/usr/bin/env bash
      case "$*" in
        *'/branches/dev'*) printf '%s\n' 'development-sha' ;;
        *'/branches/main'*) printf '%s\n' 'release-sha' ;;
        *'/compare/release-sha...development-sha'*)
          printf '%s\n' '{"status":"behind","ahead_by":0,"behind_by":2}'
          ;;
        *) exit 99 ;;
      esac
    BASH
    result = run_shell_script_with_gh(
      script,
      gh,
      'GH_TOKEN' => 'read-token',
      'REPOSITORY' => 'example/project',
      'DEVELOPMENT_BRANCH' => 'dev',
      'RELEASE_BRANCH' => 'main'
    )

    assert_predicate result, :success?, result.stderr
    assert_equal 'false', result.outputs.fetch('release_required')
    assert_equal '0', result.outputs.fetch('ahead')
    assert_equal '2', result.outputs.fetch('behind')
  end

  def test_revalidation_rejects_a_development_branch_that_moved_after_the_gate
    script = first_job(weekly_release_workflow).fetch('steps').find do |step|
      step['name'] == 'Revalidate development commit'
    end.fetch('run')
    gh = <<~'BASH'
      #!/usr/bin/env bash
      case "$*" in
        *'/branches/dev'*) printf '%s\n' 'new-development-sha' ;;
        *) exit 99 ;;
      esac
    BASH
    result = run_shell_script_with_gh(
      script,
      gh,
      'GH_TOKEN' => 'read-token',
      'REPOSITORY' => 'example/project',
      'DEVELOPMENT_BRANCH' => 'dev',
      'RELEASE_BRANCH' => 'main',
      'EXPECTED_DEVELOPMENT_SHA' => 'green-development-sha'
    )

    refute_predicate result, :success?
    assert_includes result.stderr, 'development branch moved'
  end

  def test_enabled_promotion_auto_merge_is_head_guarded
    script = first_job(weekly_release_workflow).fetch('steps').find do |step|
      step['name'] == 'Configure promotion auto-merge'
    end.fetch('run')

    Dir.mktmpdir('merge-calls') do |directory|
      calls = File.join(directory, 'calls')
      gh = <<~'BASH'
        #!/usr/bin/env bash
        printf '%s\n' "$*" >> "$MOCK_GH_CALLS"
        if [[ "$1 $2" == 'pr view' ]]; then
          printf '%s\n' '{"autoMergeRequest":null,"headRefOid":"green-sha","mergeStateStatus":"BLOCKED"}'
        fi
      BASH
      result = run_shell_script_with_gh(
        script,
        gh,
        'MOCK_GH_CALLS' => calls,
        'AUTO_MERGE' => 'true',
        'MERGE_METHOD' => 'rebase',
        'PR_NUMBER' => '12',
        'REPOSITORY' => 'example/project',
        'EXPECTED_DEVELOPMENT_SHA' => 'green-sha'
      )
      invocations = File.readlines(calls, chomp: true)

      assert_predicate result, :success?, result.stderr
      assert_equal 'requested', result.outputs.fetch('auto_merge_state')
      assert invocations.any? { |call| call.include?('pr merge 12') && call.include?('--auto') }
      assert invocations.any? { |call| call.include?('--match-head-commit green-sha') }
      assert invocations.any? { |call| call.include?('--rebase') }
      refute invocations.any? { |call| call.include?('--admin') }
    end
  end

  def test_promotion_reuses_one_matching_pull_request_and_rejects_duplicates
    script = first_job(weekly_release_workflow).fetch('steps').find do |step|
      step['name'] == 'Find or create promotion pull request'
    end.fetch('run')
    existing = [
      {
        'number' => 12,
        'url' => 'https://github.example/pulls/12',
        'headRefOid' => 'green-sha',
        'isDraft' => false
      }
    ]
    duplicates = existing + [existing.first.merge('number' => 13, 'url' => 'https://github.example/pulls/13')]

    Dir.mktmpdir('promotion-pr') do |directory|
      calls = File.join(directory, 'calls')
      gh = <<~'BASH'
        #!/usr/bin/env bash
        printf '%s\n' "$*" >> "$MOCK_GH_CALLS"
        if [[ "$1 $2" == 'pr list' ]]; then
          printf '%s\n' "$MOCK_PULL_REQUESTS"
        fi
      BASH
      environment = {
        'MOCK_GH_CALLS' => calls,
        'REPOSITORY' => 'example/project',
        'DEVELOPMENT_BRANCH' => 'dev',
        'RELEASE_BRANCH' => 'main',
        'PROMOTION_TITLE' => 'chore: promote dev to main',
        'EXPECTED_DEVELOPMENT_SHA' => 'green-sha',
        'REQUIRED_CHECK' => 'Release Gate'
      }
      reused = run_shell_script_with_gh(
        script,
        gh,
        environment.merge('MOCK_PULL_REQUESTS' => JSON.generate(existing))
      )
      duplicate = run_shell_script_with_gh(
        script,
        gh,
        environment.merge('MOCK_PULL_REQUESTS' => JSON.generate(duplicates))
      )
      invocations = File.readlines(calls, chomp: true)

      assert_predicate reused, :success?, reused.stderr
      assert_equal 'reused', reused.outputs.fetch('promotion_pr_action')
      assert_equal '12', reused.outputs.fetch('promotion_pr_number')
      refute invocations.any? { |call| call.start_with?('pr create') }
      refute_predicate duplicate, :success?
      assert_includes duplicate.stderr, 'More than one open promotion pull request'
    end
  end

end

class ReleaseWorkflowTest < Minitest::Test
  def test_release_auto_merge_handles_non_draft_release_please_pull_requests
    script = first_job(release_workflow).fetch('steps').find do |step|
      step['name'] == 'Configure release auto-merge'
    end.fetch('run')

    Dir.mktmpdir('release-merge-calls') do |directory|
      calls = File.join(directory, 'calls')
      gh = <<~'BASH'
        #!/usr/bin/env bash
        printf '%s\n' "$*" >> "$MOCK_GH_CALLS"
        if [[ "$1 $2" == 'pr view' ]]; then
          printf '%s\n' '{"autoMergeRequest":null,"headRefOid":"release-sha","isDraft":false}'
        fi
      BASH
      result = run_shell_script_with_gh(
        script,
        gh,
        'MOCK_GH_CALLS' => calls,
        'AUTO_MERGE' => 'true',
        'MERGE_METHOD' => 'squash',
        'PULL_REQUESTS' => '[{"number":34}]',
        'REPOSITORY' => 'example/project'
      )
      invocations = File.readlines(calls, chomp: true)

      assert_predicate result, :success?, result.stderr
      assert_equal 'requested:1,already-enabled:0', result.outputs.fetch('auto_merge_state')
      assert invocations.any? { |call| call.include?('pr merge 34') && call.include?('--squash') }
      assert invocations.any? { |call| call.include?('--match-head-commit release-sha') }
    end
  end

  def test_release_workflow_is_reusable_and_configurable
    workflow = release_workflow
    triggers = workflow.fetch('on')
    inputs = workflow_call_inputs(workflow)
    secrets = workflow.dig('on', 'workflow_call', 'secrets')
    release_step = workflow.dig('jobs', 'release', 'steps').find do |step|
      step['uses']&.start_with?('googleapis/release-please-action@')
    end

    assert_equal ['workflow_call'], triggers.keys
    assert_equal 'main', inputs.dig('release_branch', 'default')
    assert_equal 'php', inputs.dig('release_type', 'default')
    assert_equal true, inputs.dig('auto_merge', 'default')
    assert_equal 'merge', inputs.dig('merge_method', 'default')
    assert_equal false, secrets.dig('RELEASE_TOKEN', 'required')
    assert_equal false, secrets.dig('RELEASE_APP_CLIENT_ID', 'required')
    assert_equal false, secrets.dig('RELEASE_APP_PRIVATE_KEY', 'required')
    assert_equal 'read', workflow.dig('permissions', 'contents')
    assert_match(%r{\Agoogleapis/release-please-action@[0-9a-f]{40}\z}, release_step.fetch('uses'))
    assert_equal '${{ inputs.release_type }}', release_step.dig('with', 'release-type')
    assert_equal '${{ inputs.release_branch }}', release_step.dig('with', 'target-branch')
    refute_equal '${{ github.token }}', release_step.dig('with', 'token')
    assert_equal 'release-${{ github.repository }}-${{ inputs.release_branch }}',
                 workflow.dig('concurrency', 'group')
  end

  def test_release_workflow_checks_the_target_ref_and_auto_merges_release_please_prs
    steps = release_workflow.dig('jobs', 'release', 'steps')
    preflight = steps.find { |step| step['name'] == 'Validate release configuration' }
    auto_merge = steps.find { |step| step['name'] == 'Configure release auto-merge' }
    summary = steps.find { |step| step['name'] == 'Write release summary' }
    scripts = steps.map { |step| step['run'] }.compact.join("\n")

    assert_includes preflight.fetch('run'), 'refs/heads/${RELEASE_BRANCH}'
    assert_includes auto_merge.fetch('run'), '--match-head-commit'
    assert_includes auto_merge.fetch('run'), '--auto'
    assert_equal '${{ always() }}', summary.fetch('if')
    refute_includes scripts, '--admin'
    refute_match(/git\s+push/, scripts)
  end

  def test_release_workflows_validate_exactly_one_external_authentication_mode
    [weekly_release_workflow, release_workflow].each do |workflow|
      steps = workflow.dig('jobs').values.first.fetch('steps')
      authentication = steps.find { |step| step['name'] == 'Validate release authentication' }
      app_token = steps.find { |step| step['id'] == 'app-token' }

      assert_includes authentication.fetch('run'), 'RELEASE_TOKEN'
      assert_includes authentication.fetch('run'), 'RELEASE_APP_CLIENT_ID'
      assert_includes authentication.fetch('run'), 'RELEASE_APP_PRIVATE_KEY'
      assert_match(%r{\Aactions/create-github-app-token@[0-9a-f]{40}\z}, app_token.fetch('uses'))
      assert_equal "${{ steps.authentication.outputs.mode == 'app' }}", app_token.fetch('if')
    end
  end

end

class WorkflowsTest < Minitest::Test

  def test_tests_caller_supports_ci_and_internal_reuse
    triggers = tests_caller.fetch('on')

    assert_equal %w[dev main], triggers.dig('push', 'branches').sort
    assert_equal %w[dev main], triggers.dig('pull_request', 'branches').sort
    assert_equal %w[opened reopened synchronize], triggers.dig('pull_request', 'types').sort
    assert triggers.key?('workflow_call')
    assert_equal 'Ayup-Creative/workflows/.github/workflows/tests.yml@v1',
                 tests_caller.dig('jobs', 'quality', 'uses')
  end

end

class ReleaseWorkflowTest < Minitest::Test

  def test_release_caller_runs_on_release_branch_changes_and_manual_recovery
    workflow = release_caller
    jobs = workflow.fetch('jobs')

    assert_equal %w[push workflow_dispatch].sort, workflow.fetch('on').keys.sort
    assert_equal ['main'], workflow.dig('on', 'push', 'branches')
    assert_equal 'Ayup-Creative/workflows/.github/workflows/release.yml@v1',
                 jobs.dig('release', 'uses')
    assert_equal 'inherit', jobs.dig('release', 'secrets')
  end

end

class PromotionCallerWorkflowTest < Minitest::Test

  def test_weekly_release_caller_is_nightly_manual_and_minimal
    workflow = weekly_release_caller
    jobs = workflow.fetch('jobs')

    assert_equal %w[schedule workflow_dispatch].sort, workflow.fetch('on').keys.sort
    assert_equal '17 3 * * *', workflow.dig('on', 'schedule', 0, 'cron')
    assert_equal 'Ayup-Creative/workflows/.github/workflows/weekly-release.yml@v1',
                 jobs.dig('promotion', 'uses')
    assert_equal 'inherit', jobs.dig('promotion', 'secrets')
    refute jobs.fetch('promotion').key?('with')
  end

  def test_obsolete_finalize_release_caller_is_removed
    refute File.exist?(FINALIZE_CALLER_PATH)
  end

end
module WorkflowTestHelpers
  ROOT = Pathname(__dir__).join('..').expand_path
  TESTS_WORKFLOW_PATH = ROOT.join('.github/workflows/tests.yml')
  RELEASE_WORKFLOW_PATH = ROOT.join('.github/workflows/release.yml')
  WEEKLY_RELEASE_WORKFLOW_PATH = ROOT.join('.github/workflows/weekly-release.yml')
  TESTS_CALLER_PATH = ROOT.join('examples/tests.yml')
  RELEASE_CALLER_PATH = ROOT.join('examples/release.yml')
  WEEKLY_RELEASE_CALLER_PATH = ROOT.join('examples/weekly-release.yml')
  FINALIZE_CALLER_PATH = ROOT.join('examples/finalize-release.yml')

  private

  ResolutionResult = Struct.new(:status, :stdout, :stderr, :outputs, keyword_init: true) do
    def success?
      status.success?
    end
  end

  def load_workflow(path)
    YAML.safe_load(File.read(path), aliases: true)
  end

  def tests_workflow
    @tests_workflow ||= load_workflow(TESTS_WORKFLOW_PATH)
  end

  def release_workflow
    @release_workflow ||= load_workflow(RELEASE_WORKFLOW_PATH)
  end

  def weekly_release_workflow
    @weekly_release_workflow ||= load_workflow(WEEKLY_RELEASE_WORKFLOW_PATH)
  end

  def tests_caller
    @tests_caller ||= load_workflow(TESTS_CALLER_PATH)
  end

  def release_caller
    @release_caller ||= load_workflow(RELEASE_CALLER_PATH)
  end

  def weekly_release_caller
    @weekly_release_caller ||= load_workflow(WEEKLY_RELEASE_CALLER_PATH)
  end

  def workflow_call_inputs(workflow)
    workflow.dig('on', 'workflow_call', 'inputs')
  end

  def first_job(workflow)
    workflow.fetch('jobs').values.first
  end

  def gate_environment
    {
      'REPOSITORY' => 'example/project',
      'DEVELOPMENT_SHA' => 'abc123',
      'REQUIRED_CHECK' => 'Release Gate',
      'REQUIRED_CHECK_KIND' => 'check-run',
      'REQUIRED_CHECK_APP_ID' => ''
    }
  end

  def successful_check_run(id, app_id)
    {
      'id' => id,
      'status' => 'completed',
      'conclusion' => 'success',
      'started_at' => '2026-09-03T01:00:00Z',
      'completed_at' => '2026-09-03T01:01:00Z',
      'app' => { 'id' => app_id }
    }
  end

  def run_shell_script_with_gh(script, gh_script, environment)
    Dir.mktmpdir('workflow-gh') do |directory|
      gh = File.join(directory, 'gh')
      File.write(gh, gh_script)
      File.chmod(0o755, gh)

      return run_shell_script(
        script,
        environment.merge('PATH' => "#{directory}:#{ENV.fetch('PATH')}")
      )
    end
  end

  def run_shell_script(script, environment)
    Tempfile.create('github-output') do |output|
      Tempfile.create('github-summary') do |summary|
        stdout, stderr, status = Open3.capture3(
          environment.merge(
            'GITHUB_OUTPUT' => output.path,
            'GITHUB_STEP_SUMMARY' => summary.path
          ),
          'bash',
          stdin_data: script
        )
        output.rewind

        return ResolutionResult.new(
          status: status,
          stdout: stdout,
          stderr: stderr,
          outputs: output.each_line(chomp: true).to_h { |line| line.split('=', 2) }
        )
      end
    end
  end

  def setup_php_version(job)
    setup = job.fetch('steps').find { |step| step['name'] == 'Setup PHP' }

    setup.dig('with', 'php-version')
  end

  def resolve_versions(php_versions, phpstan_php_version: '8.4', lowest_php_version: '')
    step = tests_workflow.dig('jobs', 'configuration', 'steps').find do |candidate|
      candidate['id'] == 'versions'
    end

    Tempfile.create('github-output') do |output|
      _stdout, stderr, status = Open3.capture3(
        {
          'PHP_VERSIONS' => php_versions,
          'PHPSTAN_PHP_VERSION' => phpstan_php_version,
          'LOWEST_PHP_VERSION' => lowest_php_version,
          'GITHUB_OUTPUT' => output.path
        },
        'bash',
        stdin_data: step.fetch('run')
      )
      output.rewind

      return ResolutionResult.new(
        status: status,
        stderr: stderr,
        outputs: output.each_line(chomp: true).to_h { |line| line.split('=', 2) }
      )
    end
  end

  def resolve_composer_repositories(repositories)
    step = tests_workflow.dig('jobs', 'configuration', 'steps').find do |candidate|
      candidate['id'] == 'composer'
    end

    Tempfile.create('github-output') do |output|
      _stdout, stderr, status = Open3.capture3(
        {
          'COMPOSER_REPOSITORIES' => repositories,
          'GITHUB_OUTPUT' => output.path
        },
        'bash',
        stdin_data: step.fetch('run')
      )
      output.rewind

      return ResolutionResult.new(
        status: status,
        stderr: stderr,
        outputs: output.each_line(chomp: true).to_h { |line| line.split('=', 2) }
      )
    end
  end

  def composer_setup_script
    jobs = tests_workflow.fetch('jobs')
    scripts = %w[tests analysis lowest].map do |job|
      jobs.fetch(job).fetch('steps').find { |step| step['name'] == 'Configure Composer repositories' }&.fetch('run')
    end

    assert scripts.all?
    assert_equal 1, scripts.uniq.length

    scripts.first
  end
end

WorkflowsTest.include(WorkflowTestHelpers)
PromotionWorkflowsTest.include(WorkflowTestHelpers)
PromotionCallerWorkflowTest.include(WorkflowTestHelpers)
ReleaseWorkflowTest.include(WorkflowTestHelpers)
