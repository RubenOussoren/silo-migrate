# frozen_string_literal: true

require "oj"

module SiloMigrate
  module JSONToSQL
    # Builds table definitions directly from a Draft-07 JSON Schema file,
    # walking the same flattening/unwrap rules as the Shredder (and
    # registering every name in the shared NameRegistry so the emit pass
    # produces identical names). x-pii annotations become column comments
    # plus rows for the dump-wide _json_meta manifest.
    class JsonSchemaLoader
      TablePlan = Struct.new(:rel, :defs, :child, keyword_init: true)
      PiiEntry = Struct.new(:table_rel, :column, :json_path, :note, keyword_init: true)
      Result = Struct.new(:plans, :root_name, :pii, :forced_json, keyword_init: true)

      MIN_ENUM_VARCHAR = 32

      def initialize(registry:, max_depth: 5, graphql_unwrap: true, raw_dates: false)
        @registry = registry
        @max_depth = max_depth
        @graphql_unwrap = graphql_unwrap
        @raw_dates = raw_dates
      end

      def load(schema_path, records_path: nil)
        begin
          @schema = Oj.load_file(schema_path.to_s, mode: :strict)
        rescue Oj::ParseError, EncodingError => e
          raise UsageError, "Could not parse JSON Schema #{schema_path}: #{e.message}"
        end
        raise UsageError, "JSON Schema #{schema_path} is not an object schema" unless @schema.is_a?(Hash)

        @plans = {}
        @pii = []
        @forced_json = Set.new
        record_schema = detect_record_schema(records_path)
        walk_object(resolve(record_schema), [], "", parent_required: true)
        Result.new(plans: @plans, root_name: root_name, pii: @pii, forced_json: @forced_json)
      end

      private

      def root_name
        properties = @schema["properties"] || {}
        const = properties.dig("object_name", "const")
        const.is_a?(String) ? const : nil
      end

      def detect_record_schema(records_path)
        properties = @schema["properties"]
        return @schema unless properties.is_a?(Hash)

        key = records_path || "data"
        candidate = properties[key]
        if candidate.nil? && records_path.nil?
          array_keys = properties.keys.select { |name| array_schema?(resolve(properties[name])) }
          candidate = properties[array_keys.first] if array_keys.length == 1
        end
        candidate = resolve(candidate) if candidate
        return candidate["items"] || {} if candidate && array_schema?(candidate)

        raise UsageError, "JSON Schema has no array under records path '#{records_path}'" if records_path

        @schema
      end

      def array_schema?(schema)
        types(schema).include?("array")
      end

      def types(schema)
        Array(schema["type"]).map(&:to_s)
      end

      def resolve(schema, visited = Set.new)
        ref = schema.is_a?(Hash) ? schema["$ref"] : nil
        return schema unless ref

        raise UsageError, "Unsupported JSON Schema $ref: #{ref}" unless ref.start_with?("#/")
        raise UsageError, "Circular JSON Schema $ref: #{ref}" if visited.include?(ref)

        visited << ref
        target = ref.delete_prefix("#/").split("/").reduce(@schema) { |node, part| node.is_a?(Hash) ? node[part] : nil }
        raise UsageError, "Unresolvable JSON Schema $ref: #{ref}" unless target.is_a?(Hash)

        resolve(target, visited)
      end

      def plan_for(rel)
        @plans[rel] ||= TablePlan.new(rel: rel, defs: [], child: !rel.empty?)
      end

      def walk_object(schema, path, rel, parent_required:)
        plan_for(rel)
        properties = schema["properties"]
        return unless properties.is_a?(Hash)

        required = Array(schema["required"])
        properties.each do |key, raw_sub|
          sub = resolve(raw_sub)
          new_path = path + [key]
          not_null = parent_required && required.include?(key) && !types(sub).include?("null")
          base_types = types(sub) - ["null"]

          if base_types == ["object"] || (base_types.empty? && sub["properties"].is_a?(Hash))
            handle_object(sub, new_path, rel, not_null: not_null)
          elsif base_types == ["array"]
            handle_array(sub, new_path, rel, not_null: not_null)
          elsif base_types.length == 1 && %w[string integer number boolean].include?(base_types.first)
            add_column(sub, new_path, rel, base_types.first, not_null: not_null)
          else
            # Untyped, mixed-type, or unsupported: keep raw JSON.
            add_json_column(sub, new_path, rel, not_null: not_null)
          end
        end
      end

      def handle_object(schema, path, rel, not_null:)
        if @graphql_unwrap && (node_schema = unwrap_edges(schema))
          child_rel = @registry.child_rel(rel, path)
          walk_object(resolve(node_schema), [], child_rel, parent_required: true)
        elsif !schema["properties"].is_a?(Hash) || path.length >= @max_depth
          add_json_column(schema, path, rel, not_null: not_null)
        else
          walk_object(schema, path, rel, parent_required: not_null)
        end
      end

      def handle_array(schema, path, rel, not_null:)
        return add_json_column(schema, path, rel, not_null: not_null) if path.length >= @max_depth

        items = schema["items"]
        items = resolve(items) if items.is_a?(Hash)
        item_types = items.is_a?(Hash) ? types(items) - ["null"] : []

        if item_types == ["object"] || (items.is_a?(Hash) && items["properties"].is_a?(Hash))
          child_rel = @registry.child_rel(rel, path)
          walk_object(items, [], child_rel, parent_required: true)
        elsif item_types.length == 1 && %w[string integer number boolean].include?(item_types.first)
          child_rel = @registry.child_rel(rel, path)
          plan = plan_for(child_rel)
          kind, sql_type = scalar_type(items, item_types.first)
          plan.defs << ColumnDef.new(name: "value", kind: kind, sql_type: sql_type, null: true, comment: nil)
        else
          add_json_column(schema, path, rel, not_null: not_null)
        end
      end

      def add_column(schema, path, rel, base_type, not_null:)
        name = @registry.column_name(rel, path, :scalar)
        kind, sql_type = scalar_type(schema, base_type)
        plan_for(rel).defs << ColumnDef.new(name: name, kind: kind, sql_type: sql_type, null: !not_null, comment: pii_comment(schema))
        record_pii(schema, rel, name, path)
      end

      def add_json_column(schema, path, rel, not_null:)
        name = @registry.column_name(rel, path, :json)
        @forced_json << [rel, path.join("\0")]
        plan_for(rel).defs << ColumnDef.new(name: name, kind: :json, sql_type: "LONGTEXT", null: !not_null, comment: pii_comment(schema))
        record_pii(schema, rel, name, path)
      end

      def scalar_type(schema, base_type)
        case base_type
        when "integer" then [:integer, "BIGINT"]
        when "number" then [:float, "DOUBLE"]
        when "boolean" then [:boolean, "TINYINT(1)"]
        else string_type(schema)
        end
      end

      def string_type(schema)
        return [:datetime, "DATETIME"] if schema["format"] == "date-time" && !@raw_dates

        enum_values = Array(schema["enum"]).compact.map(&:to_s)
        if enum_values.any?
          [:string, "VARCHAR(#{[enum_values.map(&:length).max, MIN_ENUM_VARCHAR].max})"]
        elsif schema["maxLength"].is_a?(Integer) && schema["maxLength"] <= 255
          [:string, "VARCHAR(#{schema['maxLength']})"]
        else
          [:string, "TEXT"]
        end
      end

      # Schema-shape counterpart of the Shredder's GraphQL unwrap: an object
      # whose sole property is an "edges" array of objects whose sole
      # property is "node". Returns the node schema.
      def unwrap_edges(schema)
        properties = schema["properties"]
        return nil unless properties.is_a?(Hash) && properties.keys == ["edges"]

        edges = resolve(properties["edges"])
        return nil unless array_schema?(edges)

        items = edges["items"]
        items = resolve(items) if items.is_a?(Hash)
        return nil unless items.is_a?(Hash) && items["properties"].is_a?(Hash) && items["properties"].keys == ["node"]

        items["properties"]["node"]
      end

      def pii_comment(schema)
        schema["x-pii"] == true ? "x-pii" : nil
      end

      def record_pii(schema, rel, column, path)
        return unless schema["x-pii"] == true

        @pii << PiiEntry.new(table_rel: rel, column: column, json_path: path.join("."), note: schema["x-pii-note"])
      end
    end
  end
end
