# frozen_string_literal: true

require "stringio"
require "fileutils"

module SiloMigrate
  module Runtime
    class Fake
      attr_reader :commands, :operations, :running_containers, :last_stdin, :healthy_containers, :last_run_options
      attr_accessor :schema_metadata

      def initialize
        @commands = []
        @operations = []
        @running_containers = {}
        @healthy_containers = {}
        @schema_metadata = default_schema_metadata
      end

      def compose(customer, args, capture: false, timeout: 300)
        @operations << [:compose, customer, args, capture, timeout]
        @commands << [:compose, customer, args, capture, timeout]
        CommandResult.new(success?: true, stdout: capture ? "NAME STATUS\n" : "", stderr: "", status: 0)
      end

      def container_running?(name)
        @operations << [:container_running?, name]
        @running_containers.fetch(name, true)
      end

      def wait_for_container_healthy(container_name, timeout:)
        @operations << [:wait_for_container_healthy, container_name, timeout]
        @commands << [:wait_for_health, container_name, timeout]
        @healthy_containers.fetch(container_name, true)
      end

      def exec_import_command(container_name, db_type, db_name, password, max_packet: nil, disable_keys: false)
        @operations << [:exec_import_command, container_name, db_type, db_name, max_packet, disable_keys]
        Runtime::Docker.new.exec_import_command(
          container_name,
          db_type,
          db_name,
          password,
          max_packet: max_packet,
          disable_keys: disable_keys
        )
      end

      def schema_dump_command(container_name, db_type, db_name, password)
        @operations << [:schema_dump_command, container_name, db_type, db_name]
        Runtime::Docker.new.schema_dump_command(container_name, db_type, db_name, password)
      end

      def schema_metadata_commands(container_name, db_type, db_name, password)
        @operations << [:schema_metadata_commands, container_name, db_type, db_name]
        {
          tables: ["fake-schema-metadata", "tables", db_type, db_name],
          columns: ["fake-schema-metadata", "columns", db_type, db_name],
          indexes: ["fake-schema-metadata", "indexes", db_type, db_name]
        }
      end

      def run(cmd, chdir: nil, capture: false, timeout: nil, stdin_data: nil, separate_process_group: true)
        @operations << [:run, cmd, chdir, capture, timeout, stdin_data&.bytesize, separate_process_group]
        @last_run_options = {
          chdir: chdir,
          capture: capture,
          timeout: timeout,
          stdin_data_bytes: stdin_data&.bytesize,
          separate_process_group: separate_process_group
        }
        @commands << [:run, cmd, chdir, capture, timeout, stdin_data&.bytesize]
        if cmd[0, 3] == ["git", "clone", "-b"]
          converter_dir = cmd.last
          FileUtils.mkdir_p(converter_dir)
          File.write(File.join(converter_dir, "Gemfile"), "source 'https://rubygems.org'\n")
          File.write(File.join(converter_dir, "convert"), "#!/usr/bin/env ruby\n")
        end
        stdout = if cmd.first == "fake-schema-metadata"
                   @schema_metadata.fetch(cmd[1].to_sym, "")
                 elsif cmd.include?("mysqldump") || cmd.include?("pg_dump")
                   "CREATE TABLE exported (id int);\n"
                 else
                   ""
                 end
        CommandResult.new(success?: true, stdout: stdout, stderr: "", status: 0)
      end

      def run_with_stdin(cmd, chdir: nil)
        @operations << [:run_with_stdin, cmd, chdir]
        bytes = 0
        sink = StringIO.new
        yield sink
        @last_stdin = sink.string
        bytes = @last_stdin.bytesize
        @commands << [:run_stream, cmd, chdir, bytes]
        CommandResult.new(success?: true, stdout: "", stderr: "", status: 0)
      end

      private

      def default_schema_metadata
        {
          tables: "main\texported\t2\t16384\t8192\tInnoDB\tutf8mb4_unicode_ci\n",
          columns: [
            "main\texported\tid\t1\tint\tint\tNO\t\tPRI\tauto_increment\t\t",
            "main\texported\tname\t2\tvarchar(255)\tvarchar\tYES\t\t\t\tutf8mb4\tutf8mb4_unicode_ci"
          ].join("\n") + "\n",
          indexes: "main\texported\tPRIMARY\t1\tid\t0\tBTREE\n"
        }
      end
    end
  end
end
