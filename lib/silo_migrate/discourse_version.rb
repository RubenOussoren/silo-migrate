# frozen_string_literal: true

require "rubygems/version"

module SiloMigrate
  # Public version metadata only, never a core revision. dev/custom suffixes are
  # unsupported. Shared conformance cases live in discourse-versions.json.
  module DiscourseVersion
    # Release components reject leading zeros; historical suffix counters may
    # be zero-padded. All numeric conversions are bounded to at most four digits.
    NUMBER = /(?:0|[1-9][0-9]{0,3})/
    MONTH = /(?:0|[1-9][0-9]?)/
    RELEASE = /#{NUMBER}\.#{MONTH}\.#{NUMBER}/
    SUFFIX = /(?:-latest(?:[.-][0-9]{1,4})?|[.-](?:beta|rc)[0-9]{1,4}(?:[.-][0-9]{1,4})*)?/
    FILE_VERSION = /#{NUMBER}-#{MONTH}-#{NUMBER}#{SUFFIX}/

    # Returns canonical, track, release and comparable Gem::Version, or nil.
    def self.parse(value)
      return unless value.is_a?(String) && value.length <= 128
      match = value.match(/\A(#{RELEASE})(#{SUFFIX})\z/)
      return unless match

      release = match[1].split(".").map(&:to_i).join(".")
      suffix = match[2]
      track = if suffix.start_with?("-latest") then "latest"
              elsif suffix.empty? then "stable"
              else "tests-passed"
              end
      suffix = if track == "latest"
                 suffix.sub(/-latest[.-]([0-9]+)\z/) { "-latest.#{$1.to_i}" }
               elsif track == "tests-passed"
                 suffix.sub(/\A[.-](beta|rc)/, '.\1').gsub(/[-.]([0-9]+)/) { ".#{$1.to_i}" }
               else suffix
               end
      # betaN/rcN's first number has no dot prefix.
      suffix = suffix.sub(/(beta|rc)([0-9]+)/) { "#{$1}#{$2.to_i}" }
      canonical = release + suffix
      { canonical: canonical, track: track, release: release, version: Gem::Version.new(canonical) }
    end

    # Schema-only legacy names are accepted at scan time, with a nil version;
    # automatic selection must refuse them rather than guess an application.
    def self.backup(name, extension: "sql.gz")
      return unless name.is_a?(String)
      match = File.basename(name).match(/-v(?:(#{FILE_VERSION})-)?([0-9]{14})\.#{Regexp.escape(extension)}\z/)
      return unless match

      parsed = parse(match[1].sub(/\A([0-9]+)-([0-9]+)-([0-9]+)/, '\1.\2.\3')) if match[1]
      return if match[1] && !parsed

      { "discourse_version" => parsed && parsed[:canonical], "schema_version" => match[2] }
    end
  end
end
