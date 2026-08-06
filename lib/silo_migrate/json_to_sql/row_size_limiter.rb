# frozen_string_literal: true

module SiloMigrate
  module JSONToSQL
    # Keeps generated utf8mb4 table definitions below MySQL/MariaDB's
    # 65,535-byte internal row-size limit. TEXT-family values contribute only
    # an off-page pointer to that limit, so wide non-indexed VARCHAR columns
    # are promoted to TEXT until the definition fits with safety headroom.
    class RowSizeLimiter
      MAX_ROW_BYTES = 64_000
      TEXT_POINTER_BYTES = 12
      FIXED_OVERHEAD_BYTES = 64
      UTF8MB4_BYTES_PER_CHAR = 4

      Result = Struct.new(:defs, :estimated_before, :estimated_after, :promoted, keyword_init: true)

      def fit(defs, child: false)
        adjusted = defs.map(&:dup)
        estimated_before = estimate(adjusted, child: child)
        estimated_after = estimated_before
        promoted = []

        promotion_candidates(adjusted).each do |column|
          break if estimated_after <= MAX_ROW_BYTES

          column.sql_type = "TEXT"
          promoted << column.name
          estimated_after = estimate(adjusted, child: child)
        end

        if estimated_after > MAX_ROW_BYTES
          raise UsageError, "Generated table definition is too wide for MySQL/MariaDB " \
                            "(estimated #{estimated_after} bytes after promoting all non-indexed VARCHAR columns; " \
                            "maximum safe size #{MAX_ROW_BYTES} bytes). Reduce the JSON flattening depth or use JSON columns."
        end

        Result.new(
          defs: adjusted,
          estimated_before: estimated_before,
          estimated_after: estimated_after,
          promoted: promoted
        )
      end

      def estimate(defs, child: false)
        column_count = defs.length + (child ? 4 : 1)
        metadata_bytes = child ? 3 * 8 + varchar_bytes(255) : 8
        null_bitmap_bytes = (column_count + 7) / 8

        FIXED_OVERHEAD_BYTES + metadata_bytes + null_bitmap_bytes + defs.sum { |column| sql_type_bytes(column.sql_type) }
      end

      private

      def promotion_candidates(defs)
        defs.each_with_index
            .select { |column, _index| column.name != "id" && varchar?(column.sql_type) }
            .sort_by { |column, index| [-sql_type_bytes(column.sql_type), -index] }
            .map(&:first)
      end

      def sql_type_bytes(sql_type)
        varchar_match = sql_type.match(/\AVARCHAR\((\d+)\)\z/i)
        return varchar_bytes(varchar_match[1].to_i) if varchar_match
        return TEXT_POINTER_BYTES if sql_type.match?(/\A(?:TINY|MEDIUM|LONG)?TEXT\z/i)

        case sql_type.upcase
        when "TINYINT(1)" then 1
        when "BIGINT", "DOUBLE", "DATETIME" then 8
        else 16
        end
      end

      def varchar?(sql_type)
        sql_type.match?(/\AVARCHAR\(\d+\)\z/i)
      end

      def varchar_bytes(characters)
        data_bytes = characters * UTF8MB4_BYTES_PER_CHAR
        data_bytes + (data_bytes > 255 ? 2 : 1)
      end
    end
  end
end
