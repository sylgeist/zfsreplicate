require 'test_helper'
require 'zfsreplicate/executor'

class TestLocalExecutor < Minitest::Test
  def setup
    @exec = ZFSReplicate::Executor.local
  end

  def test_captures_stdout
    out = @exec.run('echo hello')
    assert_equal "hello\n", out
  end

  def test_raises_on_nonzero_exit
    err = assert_raises(ZFSReplicate::ExecutorError) do
      @exec.run('false')
    end
    assert_match /exited with status 1/, err.message
  end

  def test_run_with_pipe_streams_stdin_to_remote
    # cat reads stdin and writes to stdout
    out = @exec.run_pipeline('echo payload', 'cat')
    assert_equal "payload\n", out
  end

  def test_local_executes_in_shell
    out = @exec.run('echo $((2+2))')
    assert_equal "4\n", out
  end

  def test_pipeline_raises_when_source_side_fails
    # The left (send) side fails; the right (recv) side would otherwise succeed.
    err = assert_raises(ZFSReplicate::ExecutorError) do
      @exec.run_pipeline('echo boom >&2; false', 'cat')
    end
    assert_match /pipeline failed/, err.message
    assert_match /boom/, err.message
  end

  def test_pipeline_raises_when_dest_side_fails
    err = assert_raises(ZFSReplicate::ExecutorError) do
      @exec.run_pipeline('echo payload', 'false')
    end
    assert_match /pipeline failed/, err.message
  end

  def test_pipeline_three_stages_stream_through_middle
    out = @exec.run_pipeline('echo payload', 'tr a-z A-Z', 'cat')
    assert_equal "PAYLOAD\n", out
  end

  def test_pipeline_raises_when_middle_stage_fails
    err = assert_raises(ZFSReplicate::ExecutorError) do
      @exec.run_pipeline('echo payload', 'false', 'cat')
    end
    assert_match(/pipeline failed/, err.message)
  end
end

class TestRemoteExecutor < Minitest::Test
  def test_builds_ssh_command
    exec = ZFSReplicate::Executor.remote(host: '10.0.0.1', user: 'root')
    assert_includes exec.ssh_prefix, 'ssh'
    assert_includes exec.ssh_prefix, 'root@10.0.0.1'
  end

  def test_ssh_prefix_includes_batch_mode
    exec = ZFSReplicate::Executor.remote(host: '10.0.0.1', user: 'root')
    assert_includes exec.ssh_prefix, '-o BatchMode=yes'
  end

  def test_ssh_prefix_includes_identity_when_given
    exec = ZFSReplicate::Executor.remote(host: '10.0.0.1', user: 'root', identity: '/root/.ssh/k')
    assert_includes exec.ssh_prefix, '-i /root/.ssh/k'
  end

  def test_ssh_prefix_omits_identity_when_absent
    exec = ZFSReplicate::Executor.remote(host: '10.0.0.1', user: 'root')
    refute_includes exec.ssh_prefix, '-i '
  end

  def test_pipeline_wraps_only_first_stage_when_remote
    # 'echo' stands in for the ssh prefix; if the first stage is wrapped, the
    # pipeline runs `echo SRC | cat | cat` -> "SRC\n". If it were NOT wrapped,
    # it would try to run the command `SRC` and fail. Later stages must pass
    # through unwrapped (plain `cat`).
    exec = ZFSReplicate::Executor.new('echo')
    out = exec.run_pipeline('SRC', 'cat', 'cat')
    assert_equal "SRC\n", out
  end

  def test_ssh_prefix_includes_liveness_options
    exec = ZFSReplicate::Executor.remote(host: '10.0.0.1', user: 'root')
    assert_includes exec.ssh_prefix, '-o ConnectTimeout=10'
    assert_includes exec.ssh_prefix, '-o ServerAliveInterval=15'
    assert_includes exec.ssh_prefix, '-o ServerAliveCountMax=3'
  end
end
