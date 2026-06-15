# frozen_string_literal: true

module SiloMigrate
  # MySQL/MariaDB literal and identifier escaping shared by the XML and JSON
  # dump converters.
  module SqlText
    module_function

    def escape_sql_string(value)
      return "NULL" if value.nil?

      escaped = value.to_s
                     .gsub("\\", "\\\\\\")
                     .gsub("'", "\\\\'")
                     .gsub("\n", "\\n")
                     .gsub("\r", "\\r")
                     .gsub("\t", "\\t")
                     .gsub("\x00", "\\0")
                     .gsub("\x1a", "\\Z")
      "'#{escaped}'"
    end

    def escape_identifier(name)
      "`#{name.to_s.gsub('`', '``')}`"
    end
  end
end
