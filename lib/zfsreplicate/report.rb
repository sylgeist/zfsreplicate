# frozen_string_literal: true
# lib/zfsreplicate/report.rb
module ZFSReplicate
  module Report
    STATUS_LABELS = { ok: 'ok', failed: 'FAILED', skipped: 'skipped' }.freeze

    # results: objects responding to #name, #status (:ok/:failed/:skipped),
    # #duration (seconds), #error (String or nil). Returns Array<String>.
    def self.summary_lines(results)
      width = results.map { |r| r.name.length }.max || 0
      lines = ['Summary:']
      results.each do |r|
        label = STATUS_LABELS.fetch(r.status, r.status.to_s)
        duration = r.status == :skipped ? '-' : format('%.1fs', r.duration)
        row = format('  %-*s  %-7s  %6s', width, r.name, label, duration)
        row += "  #{r.error}" if r.error
        lines << row
      end
      counts = Hash.new(0)
      results.each { |r| counts[r.status] += 1 }
      lines << "#{counts[:ok]} ok, #{counts[:failed]} failed, #{counts[:skipped]} skipped"
      lines
    end
  end
end
