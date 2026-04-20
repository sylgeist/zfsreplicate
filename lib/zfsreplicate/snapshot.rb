# lib/zfsreplicate/snapshot.rb
require 'time'

module ZFSReplicate
  Snapshot = Struct.new(:dataset, :tag, :time, :prefix) do
    PATTERN = /\A(.+)-(\d{8})-(\d{6})\z/

    def self.generate_name(dataset, prefix:, time: Time.now)
      utc = time.utc
      "#{dataset}@#{prefix}-#{utc.strftime('%Y%m%d-%H%M%S')}"
    end

    def self.parse(full_name)
      dataset, tag = full_name.split('@', 2)
      raise ArgumentError, "Not a snapshot name: #{full_name}" unless tag

      if (m = PATTERN.match(tag))
        prefix = m[1]
        begin
          t = Time.utc(
            m[2][0, 4].to_i, m[2][4, 2].to_i, m[2][6, 2].to_i,
            m[3][0, 2].to_i, m[3][2, 2].to_i, m[3][4, 2].to_i
          )
          new(dataset, tag, t, prefix)
        rescue ArgumentError
          new(dataset, tag, nil, nil)
        end
      else
        new(dataset, tag, nil, nil)
      end
    end

    def <=>(other)
      return nil unless other.is_a?(Snapshot)
      [time || Time.at(0), tag] <=> [other.time || Time.at(0), other.tag]
    end

    include Comparable
  end
end
