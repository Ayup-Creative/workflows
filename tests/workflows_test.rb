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
  TESTS_CALLER_PATH = ROOT.join('examples/tests.yml')
  RELEASE_CALLER_PATH = ROOT.join('examples/release.yml')
  FINALIZE_CALLER_PATH = ROOT.join('examples/finalize-release.yml')

  def test_reusable_workflows_live_in_the_supported_directory
    assert File.exist?(TESTS_WORKFLOW_PATH), "Expected #{TESTS_WORKFLOW_PATH} to exist"
    assert File.exist?(RELEASE_WORKFLOW_PATH), "Expected #{RELEASE_WORKFLOW_PATH} to exist"
    refute File.exist?(ROOT.join('.github/tests.yml'))
    refute File.exist?(ROOT.join('.github/release.yml'))
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

  def test_release_workflow_is_reusable_only_and_uses_least_scoped_write_permissions
    workflow = release_workflow
    triggers = workflow.fetch('on')
    permissions = workflow.dig('jobs', 'release', 'permissions')
    release_step = workflow.dig('jobs', 'release', 'steps').find do |step|
      step['uses']&.start_with?('googleapis/release-please-action@')
    end

    assert_equal ['workflow_call'], triggers.keys
    assert_equal 'main', workflow_call_inputs(workflow).dig('target_branch', 'default')
    assert_equal false, workflow_call_inputs(workflow).dig('cleanup_release_branch', 'default')
    assert_equal 'read', workflow.dig('permissions', 'contents')
    assert_equal({
                   'contents' => 'write',
                   'issues' => 'write',
                   'pull-requests' => 'write'
                 }, permissions)
    assert_equal 'googleapis/release-please-action@v5', release_step.fetch('uses')
    assert_equal '${{ github.token }}', release_step.dig('with', 'token')
    assert_equal 'php', release_step.dig('with', 'release-type')
  end

  def test_release_workflow_checks_the_target_ref_and_guards_cleanup
    steps = release_workflow.dig('jobs', 'release', 'steps')
    preflight = steps.find { |step| step['name'] == 'Verify target branch' }
    cleanup = steps.find { |step| step['name'] == 'Delete release-please branch' }

    assert_includes preflight.fetch('run'), 'refs/heads/${TARGET_BRANCH}'
    assert_equal(
      "${{ inputs.cleanup_release_branch && steps.release.outputs.release_created == 'true' }}",
      cleanup.fetch('if')
    )
    assert_includes cleanup.fetch('run'), 'release-please*'
    assert_includes cleanup.fetch('run'), 'git/refs/heads/${RELEASE_BRANCH}'
  end

  def test_tests_caller_supports_ci_and_internal_reuse
    triggers = tests_caller.fetch('on')

    assert_equal %w[dev main], triggers.dig('push', 'branches').sort
    assert_equal %w[dev main], triggers.dig('pull_request', 'branches').sort
    assert_equal %w[opened reopened synchronize], triggers.dig('pull_request', 'types').sort
    assert triggers.key?('workflow_call')
    assert_equal 'mykemeynell/workflows/.github/workflows/tests.yml@v1',
                 tests_caller.dig('jobs', 'quality', 'uses')
  end

  def test_release_caller_is_manual_only_and_quality_gated
    workflow = release_caller
    jobs = workflow.fetch('jobs')

    assert_equal ['workflow_dispatch'], workflow.fetch('on').keys
    assert_equal 'preflight', jobs.dig('quality', 'needs')
    assert_equal 'quality', jobs.dig('release', 'needs')
    assert_equal './.github/workflows/tests.yml', jobs.dig('quality', 'uses')
    assert_equal 'mykemeynell/workflows/.github/workflows/release.yml@v1',
                 jobs.dig('release', 'uses')
  end

  def test_finalize_caller_only_handles_merged_release_please_pull_requests
    workflow = finalize_caller
    jobs = workflow.fetch('jobs')
    condition = jobs.dig('quality', 'if')

    assert_equal ['closed'], workflow.dig('on', 'pull_request', 'types')
    assert_equal ['main'], workflow.dig('on', 'pull_request', 'branches')
    assert_includes condition, 'github.event.pull_request.merged == true'
    assert_includes condition, "startsWith(github.event.pull_request.head.ref, 'release-please')"
    assert_equal 'quality', jobs.dig('release', 'needs')
    assert_equal true, jobs.dig('release', 'with', 'cleanup_release_branch')
  end

  private

  ResolutionResult = Struct.new(:status, :stderr, :outputs, keyword_init: true) do
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

  def tests_caller
    @tests_caller ||= load_workflow(TESTS_CALLER_PATH)
  end

  def release_caller
    @release_caller ||= load_workflow(RELEASE_CALLER_PATH)
  end

  def finalize_caller
    @finalize_caller ||= load_workflow(FINALIZE_CALLER_PATH)
  end

  def workflow_call_inputs(workflow)
    workflow.dig('on', 'workflow_call', 'inputs')
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
