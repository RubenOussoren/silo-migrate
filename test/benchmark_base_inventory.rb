# frozen_string_literal: true

# Opt-in, invented-data benchmark (not a CI timing assertion).
# git show e9c0ef0:lib/silo_migrate/services/standard_review_run.rb | \
#   ruby -Ilib test/benchmark_base_inventory.rb --original-stdin
# The supplied original method and current method read the SAME generated gzip file.
require "silo_migrate"
require "tmpdir"
require "json"
require "digest"

original = if ARGV.delete("--original-stdin")
             source = STDIN.read
             method = source[/^      def base_site_dump_migrations!\(path\).*?(?=^      def )/m]
             raise "original method missing" unless method

             mod = Module.new
             mod.module_eval("# frozen_string_literal: true\n#{method}", "original_base_inventory", 1)
             # Preserve the original method's lexical error constant resolution.
             mod.const_set(:StandardWorkflowError, SiloMigrate::StandardWorkflowError)
             Object.new.extend(mod)
           end
current = Object.new.extend(SiloMigrate::Services::StandardReviewRun)
mib = Integer(ENV.fetch("INVENTORY_MIB", "64"))
repeats = Integer(ENV.fetch("INVENTORY_REPEATS", "3"))
raise "positive sizes/repeats required" unless mib.positive? && repeats.positive?
header = "COPY public.schema_migrations (version) FROM stdin;\n20261104011110\n\\.\n"
# A bounded batch well beyond gzip's 32 KiB window: IDs and deterministic
# random hex payloads vary across 8,192 short rows. Reusing this large batch
# keeps generation bounded without making the whole fixture trivially compressible.
random_seed = 20261113
random = Random.new(random_seed)
varied_rows = Array.new(8192) { |i| "#{i}\t#{random.bytes(32).unpack1('H*')}\n" }.join

puts JSON.generate(ruby: RUBY_DESCRIPTION, fixture_mib: mib, repeats: repeats,
                   varied_rows_seed: random_seed, varied_rows_count: 8192, varied_rows_batch_bytes: varied_rows.bytesize,
                   original_supplied: !original.nil?, note: "Invented rows only; generation excluded; warm filesystem; no CI timing threshold")
Dir.mktmpdir("invented-base-inventory") do |dir|
  { "many-short-rows" => "42\tinvented row\n" * 4096,
    "varied-short-rows" => varied_rows,
    "long-rows" => ("x" * (128 * 1024) + "\n"),
    "marker-boundaries" => ("schema_migrations invented non-header\n" + "x" * (64 * 1024 - 38) + "\n") }.each do |name, batch|
    path = File.join(dir, "#{name}.sql.gz")
    expanded = 0
    Zlib::GzipWriter.open(path) do |gzip|
      gzip.mtime = 0
      write = ->(text) { gzip.write(text); expanded += text.bytesize }
      # The real header's marker straddles a 64 KiB reader boundary.
      write.call("x" * (64 * 1024 - 21) + "\n")
      write.call(header)
      write.call(batch) while expanded < mib * 1024 * 1024
    end
    results = { fixture: name, expanded_bytes: expanded, compressed_bytes: File.size(path),
                gzip_sha256: Digest::SHA256.file(path).hexdigest }
    runners = { "inflate_only" => lambda {
      bytes = 0
      Zlib::GzipReader.open(path) do |gzip|
        while (chunk = gzip.read(64 * 1024)) && !chunk.empty?
          bytes += chunk.bytesize
        end
        raise "unused gzip bytes" unless gzip.unused.to_s.empty?
      end
      raise "byte count mismatch" unless bytes == expanded
    } }
    runners["original"] = -> { original.base_site_dump_migrations!(path) } if original
    runners["current"] = -> { current.send(:base_site_dump_migrations!, path) }
    measurements = Hash.new { |hash, key| hash[key] = [] }
    # Alternate parser ordering to reduce systematic warm-cache/order bias.
    repeats.times do |iteration|
      order = iteration.odd? ? runners.to_a.reverse : runners.to_a
      order.each do |label, run|
        GC.start
        allocations = GC.stat(:total_allocated_objects)
        cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        value = run.call
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu
        raise "migration mismatch" unless label == "inflate_only" || value == ["20261104011110"]
        measurements[label] << { elapsed_s: elapsed, cpu_s: cpu,
                                 allocated_objects: GC.stat(:total_allocated_objects) - allocations }
      end
    end
    results[:measurements] = measurements
    medians = measurements.transform_values { |samples| samples.map { |s| s[:elapsed_s] }.sort[samples.size / 2] }
    results[:median_elapsed_s] = medians
    results[:speedup] = medians["original"] / medians.fetch("current") if original
    puts JSON.generate(results)
  end
end
