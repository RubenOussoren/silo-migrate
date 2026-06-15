# frozen_string_literal: true

require "oj"

module SiloMigrate
  module JSONToSQL
    # Streams the records out of one JSON document without materializing the
    # whole document: only the envelope (everything outside the records array)
    # and one record at a time are held in memory.
    #
    # Records-array detection, first match wins:
    #   1. the array under the explicit records_path key (error if absent)
    #   2. the array under the top-level "data" key
    #   3. the sole top-level array value (buffered into the envelope first,
    #      so only suitable for modest non-"data" files; use records_path for
    #      huge ones)
    #   4. none: the whole document is a single record
    class RecordStreamer
      Result = Struct.new(:envelope, :records_key, :record_count, :truncated, :parse_error, keyword_init: true)

      def initialize(records_path: nil)
        @records_path = records_path
      end

      # Yields each record (a plain Hash/Array/scalar tree) with its 0-based
      # ordinal. Returns a Result with the envelope hash (records excluded).
      #
      # With recover: true, a parse failure inside the records array returns a
      # truncated Result covering the records that completed before the
      # failure (each yielded record is a fully parsed tree, so everything
      # already yielded is intact); the partial tail record is discarded.
      # Failures before the first complete record still raise.
      def each_record(io, recover: false, &block)
        handler = Handler.new(records_key: @records_path || "data", on_record: block)
        begin
          Oj.sc_parse(handler, io)
        rescue Oj::ParseError, EncodingError => e
          raise unless recover && handler.records_found && handler.record_count.positive?

          return Result.new(
            envelope: handler.envelope || {},
            records_key: handler.records_key_used,
            record_count: handler.record_count,
            truncated: true,
            parse_error: e.message.sub(/ \[\S+\]\z/, "")
          )
        end
        root = handler.root_value
        return Result.new(envelope: handler.envelope || {}, records_key: handler.records_key_used, record_count: handler.record_count) if handler.records_found

        if @records_path
          raise UsageError, "No array found under records path '#{@records_path}' in JSON input"
        end

        fallback_records(root, handler, &block)
      end

      private

      def fallback_records(root, handler, &block)
        raise UsageError, "JSON input is a bare scalar value and cannot be converted" unless root.is_a?(Hash)

        envelope = handler.envelope

        array_keys = envelope.keys.select { |key| envelope[key].is_a?(Array) }
        if array_keys.length == 1
          key = array_keys.first
          records = envelope.delete(key)
          records.each_with_index(&block)
          Result.new(envelope: envelope, records_key: key, record_count: records.length)
        else
          block.call(envelope, 0)
          Result.new(envelope: {}, records_key: nil, record_count: 1)
        end
      end

      # rubocop:disable Naming/MethodName -- Oj::ScHandler callback names
      class Handler < ::Oj::ScHandler
        RECORDS = Object.new

        attr_reader :envelope, :records_key_used, :record_count, :root_value

        def initialize(records_key:, on_record:)
          super()
          @records_key = records_key
          @on_record = on_record
          @stack = []
          @pending_key = nil
          @envelope = nil
          @records_found = false
          @records_key_used = nil
          @record_count = 0
          @root_value = nil
        end

        def records_found
          @records_found
        end

        def hash_start
          hash = {}
          @envelope = hash if @stack.empty?
          @stack.push(hash)
          hash
        end

        def hash_end
          @stack.pop
        end

        def hash_key(key)
          @pending_key = key if @stack.length == 1
          key
        end

        def hash_set(hash, key, value)
          hash[key] = value unless value.equal?(RECORDS)
        end

        def array_start
          target = if @stack.empty?
                     @records_found = true
                     RECORDS
                   elsif @stack.length == 1 && @stack.first.equal?(@envelope) && @pending_key == @records_key
                     @records_found = true
                     @records_key_used = @records_key
                     RECORDS
                   else
                     []
                   end
          @stack.push(target)
          target
        end

        def array_end
          @stack.pop
        end

        def array_append(array, value)
          if array.equal?(RECORDS)
            @on_record.call(value, @record_count)
            @record_count += 1
          else
            array << value
          end
        end

        def add_value(value)
          @root_value = value
          @envelope = {} if @envelope.nil?
        end
      end
      # rubocop:enable Naming/MethodName
    end

    # IO wrapper reporting consumed bytes; Oj.sc_parse drives custom IO-like
    # objects through readpartial.
    class CountingIO
      def initialize(io, &on_bytes)
        @io = io
        @on_bytes = on_bytes
      end

      def readpartial(max_length, out_buffer = nil)
        chunk = out_buffer ? @io.readpartial(max_length, out_buffer) : @io.readpartial(max_length)
        @on_bytes.call(chunk.bytesize) if chunk
        chunk
      end

      def read(length = nil, out_buffer = nil)
        chunk = out_buffer ? @io.read(length, out_buffer) : @io.read(length)
        @on_bytes.call(chunk.bytesize) if chunk
        chunk
      end
    end
  end
end
