# frozen_string_literal: true
#
# open3_sandbox.rb — the toolkit for running shell commands properly.
#
# Open3 gives you stdout, stderr, AND exit status (backticks and `system` throw
# some of those away), plus a safe no-shell argument form.
#
# Run:  ruby examples/open3_sandbox.rb

require 'open3'

def section(title)
  puts "\n== #{title} =="
end

# 1) capture3: the workhorse. Get all three outputs at once. ------------------
section 'capture3 — stdout, stderr, status'
stdout, stderr, status = Open3.capture3('echo hello; echo oops >&2; exit 3')
puts "  stdout:   #{stdout.inspect}"
puts "  stderr:   #{stderr.inspect}"
puts "  success?: #{status.success?}"
puts "  exitcode: #{status.exitstatus}"

# 2) Shell form vs no-shell form: the injection difference. -------------------
section 'shell vs no-shell (injection safety)'
untrusted = 'hi; echo PWNED'

# ONE string -> /bin/sh -c -> the shell sees TWO commands. Dangerous.
shell_out, = Open3.capture2("echo #{untrusted}")
puts "  shell form  -> #{shell_out.inspect}   (the ; ran a second command!)"

# MANY args -> exec directly, no shell. The string is one literal argument.
safe_out, = Open3.capture2('echo', untrusted)
puts "  no-shell    -> #{safe_out.inspect}   (treated as literal text)"

# 3) Feeding stdin with stdin_data. -------------------------------------------
section 'stdin_data — pipe input into a command'
upper, = Open3.capture2('tr a-z A-Z', stdin_data: "hello world\n")
puts "  #{upper.inspect}"

# 4) capture2e — merge stdout+stderr in order (great for logging). ------------
section 'capture2e — merged streams'
merged, = Open3.capture2e('echo first; echo second >&2; echo third')
puts merged.lines.map { |l| "  #{l.chomp}" }

# 5) An environment hash and a working directory. -----------------------------
section 'env hash + chdir'
date, = Open3.capture2({ 'TZ' => 'UTC' }, 'date', '+%Z')
puts "  TZ=UTC date zone: #{date.chomp}"
where, = Open3.capture2('pwd', chdir: '/tmp')
puts "  pwd in /tmp:       #{where.chomp}"

# 6) popen3 — stream output line-by-line as the process runs. ------------------
section 'popen3 — streaming + the wait thread'
Open3.popen3('printf "a\nb\nc\n"') do |stdin, stdout, stderr, wait_thr|
  stdin.close                       # we have no input to send
  stdout.each_line { |line| puts "  streamed: #{line.chomp}" }
  stderr.read                       # drain stderr too (see deadlock note below)
  puts "  final status: #{wait_thr.value.exitstatus}"  # .value blocks til done
end

# 7) pipeline — chain commands WITHOUT a shell, and see EVERY status. ---------
section 'pipeline — all stage statuses'
statuses = Open3.pipeline('echo hello', 'tr a-z A-Z')   # like:  echo hello | tr ...
puts "  stage exit codes: #{statuses.map(&:exitstatus).inspect}"

section 'pipeline_r — capture output AND catch a LEFT-side failure'
# A shell `a | b` reports only b's exit code. pipeline_r gives you both, so a
# failed producer can't hide. (This is exactly what Executor#run_pipeline uses.)
out_io, threads = Open3.pipeline_r(['sh', '-c', 'echo data; exit 5'], ['cat'])
data = out_io.read
out_io.close
codes = threads.map { |t| t.value.exitstatus }
puts "  captured output:  #{data.inspect}"
puts "  stage exit codes: #{codes.inspect}   (left side's 5 is visible!)"
puts "  any stage failed? #{codes.any?(&:nonzero?)}"
