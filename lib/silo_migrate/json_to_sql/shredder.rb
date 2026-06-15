# frozen_string_literal: true

require "digest"
require "oj"

module SiloMigrate
  module JSONToSQL
    # A JSON value kept verbatim as serialized JSON text (fallback for shapes
    # that do not shred cleanly into columns or child tables).
    JsonValue = Struct.new(:text)

    # One shredded record: +table_rel+ is the table's path relative to the
    # root table ("" for the root itself), +columns+ maps final column names
    # to raw values, +children+ holds nested ShreddedRows for child tables.
    ShreddedRow = Struct.new(:table_rel, :columns, :children, :ordinal, :parent_natural_id)

    # Allocates deterministic, collision-free table and column names. Built
    # during the inference pass and reused verbatim during the emit pass so
    # both passes agree on every name.
    class NameRegistry
      MAX_NAME_LENGTH = 64

      attr_reader :collisions

      def initialize
        @columns = {}
        @column_owner = Hash.new { |hash, key| hash[key] = {} }
        @children = {}
        @child_owner = Hash.new { |hash, key| hash[key] = {} }
        @collisions = 0
      end

      def column_name(table_rel, raw_path, representation)
        key = [table_rel, representation, raw_path.join("\0")]
        @columns[key] ||= allocate(@column_owner[table_rel], key) do
          base = sanitize_path(raw_path)
          representation == :json ? "#{base}_json" : base
        end
      end

      def child_rel(table_rel, raw_path)
        key = [table_rel, raw_path.join("\0")]
        @children[key] ||= allocate(@child_owner[:tables], key) do
          rel = sanitize_path(raw_path)
          table_rel.empty? ? rel : "#{table_rel}_#{rel}"
        end
      end

      def self.sanitize(name)
        sanitized = name.to_s
                        .gsub(/([a-z0-9])([A-Z])/, '\1_\2')
                        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                        .downcase
                        .gsub(/[^a-z0-9_]+/, "_")
                        .squeeze("_")
                        .gsub(/\A_+|_+\z/, "")
        sanitized = "t_#{sanitized}" if sanitized.match?(/\A\d/)
        sanitized.empty? ? "unnamed" : sanitized
      end

      def self.truncate(name)
        return name if name.length <= MAX_NAME_LENGTH

        "#{name[0, MAX_NAME_LENGTH - 9]}_#{Digest::SHA1.hexdigest(name)[0, 8]}"
      end

      private

      def sanitize_path(raw_path)
        self.class.truncate(raw_path.map { |part| self.class.sanitize(part) }.join("_"))
      end

      def allocate(taken, key)
        candidate = self.class.truncate(yield)
        unless taken[candidate].nil? || taken[candidate] == key
          @collisions += 1
          suffix = 2
          suffix += 1 until taken[self.class.truncate("#{candidate}_#{suffix}")].nil?
          candidate = self.class.truncate("#{candidate}_#{suffix}")
        end
        taken[candidate] = key
        candidate
      end
    end

    # Turns one JSON record into a tree of ShreddedRows following the
    # convention-based rules: nested objects flatten into prefixed columns,
    # arrays become child tables, GraphQL edges/node wrappers unwrap, and
    # anything too deep or irregular falls back to a *_json text column.
    class Shredder
      def initialize(registry:, max_depth: 5, graphql_unwrap: true, json_column_paths: nil, forced_json_paths: nil)
        @registry = registry
        @max_depth = max_depth
        @graphql_unwrap = graphql_unwrap
        @json_column_paths = (json_column_paths || []).to_set
        @forced_json_paths = forced_json_paths || Set.new
        @json_fallbacks = 0
      end

      attr_reader :json_fallbacks

      def shred(record, ordinal)
        build_row("", record, ordinal, nil)
      end

      private

      def build_row(table_rel, record, ordinal, parent_natural_id)
        row = ShreddedRow.new(table_rel, {}, [], ordinal, parent_natural_id)
        case record
        when Hash
          walk(record, [], row, natural_id_of(record))
        when Array
          add_json_column(row, ["value"], record)
        else
          row.columns["value"] = record
        end
        row
      end

      def walk(object, path, row, natural_id)
        object.each do |key, value|
          new_path = path + [key]
          if forced_json?(row.table_rel, new_path)
            add_json_column(row, new_path, value)
            next
          end

          case value
          when Hash
            if @graphql_unwrap && (nodes = unwrap_edges(value))
              handle_array(nodes, new_path, row, natural_id)
            elsif new_path.length >= @max_depth
              add_json_column(row, new_path, value)
            else
              walk(value, new_path, row, natural_id)
            end
          when Array
            handle_array(value, new_path, row, natural_id)
          else
            row.columns[@registry.column_name(row.table_rel, new_path, :scalar)] = value
          end
        end
      end

      def handle_array(array, path, row, natural_id)
        return if array.empty?
        return add_json_column(row, path, array) if path.length >= @max_depth

        hashes, others = array.partition { |element| element.is_a?(Hash) }
        if hashes.any? && others.any? || array.any? { |element| element.is_a?(Array) }
          add_json_column(row, path, array)
        elsif hashes.any?
          rel = @registry.child_rel(row.table_rel, path)
          array.each_with_index { |element, index| row.children << build_row(rel, element, index, natural_id) }
        else
          rel = @registry.child_rel(row.table_rel, path)
          array.each_with_index do |element, index|
            row.children << ShreddedRow.new(rel, { "value" => element }, [], index, natural_id)
          end
        end
      end

      def add_json_column(row, path, value)
        @json_fallbacks += 1
        row.columns[@registry.column_name(row.table_rel, path, :json)] = JsonValue.new(Oj.dump(value, mode: :compat))
      end

      def forced_json?(table_rel, path)
        return true if @forced_json_paths.include?([table_rel, path.join("\0")])
        return false if @json_column_paths.empty? || !table_rel.empty?

        @json_column_paths.include?(path.map { |part| NameRegistry.sanitize(part) }.join("."))
      end

      # {"edges": [{"node": {...}}, ...]} unwraps to the array of node values.
      def unwrap_edges(value)
        return nil unless value.keys == ["edges"] && value["edges"].is_a?(Array)
        return nil unless value["edges"].all? { |edge| edge.is_a?(Hash) && edge.keys == ["node"] }

        value["edges"].map { |edge| edge["node"] }
      end

      def natural_id_of(record)
        id = record["id"]
        return id.to_s if id.is_a?(String) || id.is_a?(Integer)

        record.each do |key, value|
          next unless value.is_a?(String) || value.is_a?(Integer)

          sanitized = NameRegistry.sanitize(key)
          return value.to_s if sanitized == "id" || sanitized.end_with?("_id")
        end
        nil
      end
    end
  end
end
