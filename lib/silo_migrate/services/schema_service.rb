# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module SiloMigrate
  module Services
    class SchemaService
      ARTIFACT_VERSION = 1

      def initialize(runtime: Runtime::Docker.new, env: ENV, output: $stdout)
        Runtime::Contract.assert_phase_2_implemented!(runtime)
        @runtime = runtime
        @env = env
        @output = output
      end

      def bundle(customer, phase: "initial", output_dir: nil)
        config = Project.load_config(customer, @env)
        db_type, db_name, password = database_config(customer, phase, config)
        container_name = "#{customer}_#{phase}_#{db_type}"
        raise UsageError, "Container #{container_name} is not running. Start it first." unless @runtime.container_running?(container_name)

        output_dir ||= File.join(Project.project_path(customer, @env), "schema", phase)
        FileUtils.mkdir_p(output_dir)

        schema_sql = capture_schema(container_name, db_type, db_name, password)
        commands = @runtime.schema_metadata_commands(container_name, db_type, db_name, password)
        tables = parse_tables(capture_metadata(commands.fetch(:tables), "tables"))
        columns = parse_columns(capture_metadata(commands.fetch(:columns), "columns"))
        indexes = parse_indexes(capture_metadata(commands.fetch(:indexes), "indexes"))
        summary = build_summary(customer, phase, db_type, db_name, tables, columns, indexes)

        write_artifact(output_dir, "schema.sql", schema_sql)
        write_json(output_dir, "tables.json", tables)
        write_json(output_dir, "columns.json", columns)
        write_json(output_dir, "indexes.json", indexes)
        write_json(output_dir, "summary.json", summary)
        write_artifact(output_dir, "migration_notes.md", migration_notes(summary))

        @output.puts "[OK] Schema bundle exported: #{output_dir}"
        output_dir
      end

      private

      def capture_schema(container_name, db_type, db_name, password)
        result = @runtime.run(@runtime.schema_dump_command(container_name, db_type, db_name, password), capture: true)
        raise UsageError, "Schema export failed: #{result.stderr.empty? ? result.stdout : result.stderr}" unless result.success?

        result.stdout
      end

      def capture_metadata(cmd, label)
        result = @runtime.run(cmd, capture: true)
        raise UsageError, "Schema #{label} metadata export failed: #{result.stderr.empty? ? result.stdout : result.stderr}" unless result.success?

        result.stdout
      end

      def parse_tables(text)
        parse_tsv(text).map do |schema, table, rows, data_bytes, index_bytes, engine, collation|
          {
            schema: blank_to_nil(schema),
            name: table,
            row_count_estimate: integer(rows),
            data_bytes: integer(data_bytes),
            index_bytes: integer(index_bytes),
            engine: blank_to_nil(engine),
            collation: blank_to_nil(collation)
          }
        end
      end

      def parse_columns(text)
        parse_tsv(text).map do |schema, table, name, ordinal, column_type, data_type, nullable, default, key, extra, charset, collation|
          {
            schema: blank_to_nil(schema),
            table: table,
            name: name,
            ordinal_position: integer(ordinal),
            column_type: column_type,
            data_type: data_type,
            nullable: nullable.to_s.upcase == "YES",
            default: blank_to_nil(default),
            key: blank_to_nil(key),
            extra: blank_to_nil(extra),
            character_set: blank_to_nil(charset),
            collation: blank_to_nil(collation)
          }
        end
      end

      def parse_indexes(text)
        parse_tsv(text).map do |schema, table, name, sequence, column, non_unique, index_type|
          {
            schema: blank_to_nil(schema),
            table: table,
            name: name,
            sequence: integer(sequence),
            column_or_expression: blank_to_nil(column),
            unique: integer(non_unique).zero?,
            type: blank_to_nil(index_type)
          }
        end
      end

      def parse_tsv(text)
        text.lines(chomp: true).reject(&:empty?).map { |line| line.split("\t", -1) }
      end

      def build_summary(customer, phase, db_type, db_name, tables, columns, indexes)
        {
          artifact_version: ARTIFACT_VERSION,
          generated_at: Time.now.utc.iso8601,
          customer: customer,
          phase: phase,
          db_type: db_type,
          database: db_name,
          table_count: tables.length,
          column_count: columns.length,
          index_count: indexes.length,
          contains_raw_rows: false,
          dev_ai_visibility: "safe"
        }
      end

      def migration_notes(summary)
        <<~MARKDOWN
          # Schema Bundle

          Customer: #{summary.fetch(:customer)}
          Phase: #{summary.fetch(:phase)}
          Database: #{summary.fetch(:database)} (#{summary.fetch(:db_type)})

          This bundle contains schema and database metadata only. It is intended for converter development without raw customer row access.

          Tables: #{summary.fetch(:table_count)}
          Columns: #{summary.fetch(:column_count)}
          Indexes: #{summary.fetch(:index_count)}
        MARKDOWN
      end

      def write_json(dir, filename, data)
        write_artifact(dir, filename, "#{JSON.pretty_generate(data)}\n")
      end

      def write_artifact(dir, filename, content)
        Project.atomic_write(File.join(dir, filename), content)
      end

      def integer(value)
        Integer(value || 0, 10)
      rescue ArgumentError, TypeError
        0
      end

      def blank_to_nil(value)
        value.to_s.empty? ? nil : value
      end

      def database_config(customer, phase, config)
        Project.database_config(customer, phase, config)
      end
    end
  end
end
