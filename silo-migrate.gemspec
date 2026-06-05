Gem::Specification.new do |spec|
  spec.name = "silo-migrate"
  spec.version = "0.1.0"
  spec.summary = "Discourse migration database runtime helper"
  spec.description = "Ruby compatibility port of db-migration-toolkit for Docker-backed Discourse migrations."
  spec.authors = ["Discourse"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["bin/*", "lib/**/*.rb", "README.md"]
  spec.bindir = "bin"
  spec.executables = ["silo-migrate", "migration-tool", "xml-to-sql"]
  spec.require_paths = ["lib"]

  spec.add_dependency "tty-prompt", ">= 0.23", "< 1.0"
  spec.add_dependency "sqlite3", ">= 1.3", "< 3.0"
end
