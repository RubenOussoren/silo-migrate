# frozen_string_literal: true

# TEST TRANSPORT ONLY. Loaded into the unchanged installed CLI by the fixture's
# Docker wrapper. No service lifecycle, validation, SQL, claim or backup overrides.
require "bundler/setup"
require File.join(Dir.pwd, "lib/silo_migrate")
require "uri"

module ConnectedMergeDocker
  LABEL = "silo-migrate.connected-merge-live"

  def run(command, **options)
    argv = command.dup
    if argv.first == "docker"
      raise "fixture refuses image acquisition" if %w[pull build load import].include?(argv[1])
      if argv[1, 2] == %w[network create]
        argv.insert(3, "--internal") unless argv.include?("--internal")
      end
      if %w[run create].include?(argv[1]) || (argv[1, 2] == %w[network create]) || (argv[1, 2] == %w[volume create])
        at = %w[run create].include?(argv[1]) ? 2 : 3
        argv.insert(at, "--label", "#{LABEL}=#{ENV.fetch('SILO_CONNECTED_TOKEN')}")
      end
      if %w[run create].include?(argv[1])
        # Keep the real proxy, but reach it with docker exec rather than a host
        # listener. The map is only routing metadata; it is NOT run evidence.
        if (index = argv.index("-p"))
          binding = argv[index + 1]
          raise "fixture unexpected listener" unless binding.match?(/\A127\.0\.0\.1:[0-9]+:8080\z/)
          name = argv.fetch(argv.index("--name") + 1)
          path = File.join(ENV.fetch("SILO_CONNECTED_ROUTE_DIR"), binding.split(":")[1])
          File.write(path, name, mode: "w", perm: 0o600)
          argv.slice!(index, 2)
        end
        raise "fixture unexpected publish" if argv.any? { |v| v == "-P" || v.start_with?("--publish") }
      end
    end
    super(argv, **options)
  end
end
SiloMigrate::Runtime::Docker.prepend(ConnectedMergeDocker)

module ConnectedMergeHTTP
  # A genuine HTTP request through the actual socat proxy on its private network.
  # Only the socket transport differs: status and body are never manufactured.
  def http_fetch(url, limit, redirects = 3)
    uri = URI(url)
    raise "fixture refuses external HTTP" unless uri.scheme == "http" && uri.host == "127.0.0.1"
    proxy = File.read(File.join(ENV.fetch("SILO_CONNECTED_ROUTE_DIR"), uri.port.to_s))
    raise "fixture invalid route" unless proxy.match?(/\Asilomig-[a-z0-9-]+-proxy\z/)
    response = @runtime.run(["docker", "exec", proxy, "curl", "--silent", "--show-error", "--max-time", "30",
      "--header", "Host: 127.0.0.1:#{uri.port}", "--max-filesize", limit.to_s, "--write-out", "\n%{http_code}\n%{redirect_url}",
      "http://127.0.0.1:8080#{uri.request_uri}"], capture: true, timeout: 40)
    raise "fixture HTTP transport failed" unless response.success?
    body, _, redirect = response.stdout.rpartition("\n")
    body, _, code = body.rpartition("\n")
    code = Integer(code, 10)
    if code.between?(300, 399) && !redirect.empty? && redirects.positive?
      target = URI(redirect)
      target.host = "127.0.0.1"
      target.port = uri.port
      return http_fetch(target.to_s, limit, redirects - 1)
    end
    { status: code, body: body[0, limit] }
  end
end
SiloMigrate::Services::StandardWorkflowService.prepend(ConnectedMergeHTTP)
