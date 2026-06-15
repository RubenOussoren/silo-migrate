# frozen_string_literal: true

require "time"

module SiloMigrate
  module JSONToSQL
    ColumnDef = Struct.new(:name, :kind, :sql_type, :null, :comment, keyword_init: true)

    # Accumulates per-column type observations across all records of a table
    # and finalizes them into MySQL column definitions via a widening lattice:
    # unknown -> boolean | integer -> float | datetime -> string (sized into
    # VARCHAR/TEXT/MEDIUMTEXT/LONGTEXT by max byte length).
    class ColumnProfile
      ISO_DATETIME = /\A\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:?\d{2})?\z/

      attr_reader :kind, :seen_count

      def initialize(raw_dates: false)
        @raw_dates = raw_dates
        @kind = :unknown
        @max_bytes = 0
        @null_seen = false
        @seen_count = 0
      end

      def observe(value)
        @seen_count += 1
        case value
        when nil
          @null_seen = true
        when JsonValue
          @kind = :json
          @max_bytes = [@max_bytes, value.text.bytesize].max
        when true, false
          widen(:boolean)
        when Integer
          widen(:integer)
        when Float
          widen(:float)
        when String
          @max_bytes = [@max_bytes, value.bytesize].max
          widen(!@raw_dates && value.match?(ISO_DATETIME) ? :datetime : :string)
        else
          @max_bytes = [@max_bytes, value.to_s.bytesize].max
          widen(:string)
        end
      end

      def finalize(name, row_count)
        ColumnDef.new(
          name: name,
          kind: @kind,
          sql_type: sql_type,
          null: @null_seen || @seen_count < row_count
        )
      end

      private

      def widen(observed)
        return @kind = :json if @kind == :json || observed == :json
        return @kind = observed if @kind == :unknown
        return if @kind == observed

        numeric = [@kind, observed].sort == %i[float integer]
        @kind = numeric ? :float : :string
      end

      def sql_type
        case @kind
        when :boolean then "TINYINT(1)"
        when :integer then "BIGINT"
        when :float then "DOUBLE"
        when :datetime then "DATETIME"
        when :json then "LONGTEXT"
        else string_type
        end
      end

      def string_type
        if @max_bytes <= 255 then "VARCHAR(255)"
        elsif @max_bytes <= 65_535 then "TEXT"
        elsif @max_bytes <= 16_777_215 then "MEDIUMTEXT"
        else "LONGTEXT"
        end
      end
    end

    # Column profiles for one table, in first-observation order.
    class TableProfile
      attr_reader :table_rel, :row_count

      def initialize(table_rel, raw_dates: false)
        @table_rel = table_rel
        @raw_dates = raw_dates
        @columns = {}
        @row_count = 0
      end

      def observe_row(columns)
        @row_count += 1
        columns.each do |name, value|
          (@columns[name] ||= ColumnProfile.new(raw_dates: @raw_dates)).observe(value)
        end
      end

      def child?
        !@table_rel.empty?
      end

      def finalize
        @columns.map { |name, profile| profile.finalize(name, @row_count) }
      end
    end

    # Collects TableProfiles for every table produced by shredding a file.
    class SchemaInferrer
      attr_reader :profiles

      def initialize(raw_dates: false)
        @raw_dates = raw_dates
        @profiles = {}
      end

      def observe(row)
        (@profiles[row.table_rel] ||= TableProfile.new(row.table_rel, raw_dates: @raw_dates)).observe_row(row.columns)
        row.children.each { |child| observe(child) }
      end
    end
  end
end
