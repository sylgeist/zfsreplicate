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
end
