# frozen_string_literal: true

require "set"
require "socket"

module SiloMigrate
  class PortValidator
    def initialize(availability: nil, env: ENV)
      @env = env
      @availability = availability || method(:available?)
    end

    def validate!(value, label:, used: {}, allow_occupied: false)
      port = integer(value)
      raise UsageError, "#{label} port must be between 1 and 65535" unless port.between?(1, 65_535)

      duplicate = used.find { |_, other| other.to_i == port }
      if duplicate
        suggestion = next_free(port + 1, avoid: used.values)
        raise UsageError, "#{label} port #{port} duplicates #{duplicate.first}; suggested free port: #{suggestion}"
      end
      unless allow_occupied || @availability.call(port)
        suggestion = next_free(port + 1, avoid: used.values)
        raise UsageError, "#{label} port #{port} is already in use; suggested free port: #{suggestion}"
      end
      port
    rescue ArgumentError, TypeError
      raise UsageError, "#{label} port must be an integer from 1 to 65535"
    end

    def next_free(preferred, avoid: [])
      avoided = avoid.map(&:to_i).to_set
      port = [integer(preferred), 1].max
      while port <= 65_535
        return port if !avoided.include?(port) && @availability.call(port)
        port += 1
      end
      raise UsageError, "Could not find an available localhost port starting at #{preferred}"
    end

    private

    def integer(value)
      value.is_a?(String) ? Integer(value, 10) : Integer(value)
    end

    def available?(port)
      return true if @env["SILO_MIGRATE_SKIP_PORT_CHECK"] == "1"

      server = TCPServer.new("127.0.0.1", port)
      server.close
      true
    rescue Errno::EADDRINUSE, Errno::EACCES
      false
    rescue SystemCallError, IOError
      # Sandboxed runtimes may prohibit socket creation altogether. The normal
      # start-time conflict check remains the race-condition backstop.
      true
    end
  end
end
