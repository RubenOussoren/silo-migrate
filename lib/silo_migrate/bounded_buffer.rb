# frozen_string_literal: true

module SiloMigrate
  # Keeps a byte-bounded tail of streamed output so long-running commands
  # (e.g. converter runs) cannot exhaust memory while we still retain the
  # most recent output for summaries and error reporting.
  class BoundedBuffer
    DEFAULT_MAX_BYTES = 4 * 1024 * 1024

    attr_reader :byte_count

    def initialize(max_bytes: DEFAULT_MAX_BYTES)
      @max_bytes = max_bytes
      @chunks = []
      @buffered_bytes = 0
      @byte_count = 0
      @truncated = false
    end

    def write(chunk)
      chunk = chunk.to_s
      return if chunk.empty?

      @byte_count += chunk.bytesize
      @chunks << chunk
      @buffered_bytes += chunk.bytesize
      while @buffered_bytes > @max_bytes && @chunks.length > 1
        @buffered_bytes -= @chunks.shift.bytesize
        @truncated = true
      end
      return unless @buffered_bytes > @max_bytes

      oversized = @chunks[0]
      @chunks[0] = oversized.byteslice(oversized.bytesize - @max_bytes, @max_bytes)
      @buffered_bytes = @max_bytes
      @truncated = true
    end

    def truncated?
      @truncated
    end

    def tail_string
      text = @chunks.join
      text.force_encoding(Encoding::UTF_8)
      text.valid_encoding? ? text : text.scrub
    end
  end
end
