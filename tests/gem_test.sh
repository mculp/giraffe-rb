#!/usr/bin/env bash
# Builds the giraffe-rb gem and runs giraffe from what it packed, not from this checkout, so a file the library reads
# at run time that the gemspec leaves out fails here rather than for someone who installed the gem.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# No license is chosen yet, so `gem build` warns about it; only a failure matters here.
gem build giraffe-rb.gemspec --output "$work/giraffe-rb.gem" >/dev/null 2>"$work/build.err" || { cat "$work/build.err" >&2; exit 1; }
gem unpack "$work/giraffe-rb.gem" --target "$work" >/dev/null
packed="$work/giraffe-rb"

ruby "$packed/bin/giraffe" --help | grep -q "Usage: giraffe start" || { echo "giraffe --help failed from the gem" >&2; exit 1; }
echo "ok 1: the packed bin/giraffe runs"

# Every role's prompt and schema, every contract, and `require "giraffe"` by the name Bundler uses for giraffe-rb.
ruby -I "$packed/lib" -e '
  require "giraffe/rb"
  roles = Dir[File.join(Giraffe::Model::ROOT, "schemas", "*.json")].map { |path| File.basename(path, ".json") }
  abort "no roles packed" if roles.empty?
  roles.each do |role|
    request = Giraffe::Model::Request.new(role: role, attempt: 1, unit: nil, inputs: {}, cwd: ".", writable: false)
    request.schema
    abort "#{role} has no instructions" if request.instructions.strip.empty?
  end
  PrGraph::Shapes.build
  abort "loaded from the checkout, not the gem" unless Giraffe::Model::ROOT.start_with?(ARGV.first)
  puts "ok 2: require \"giraffe/rb\" loads every role (#{roles.size}) and contract from the gem"
' "$packed"
grep -q '^  spec.name = "giraffe-rb"' giraffe-rb.gemspec
echo "2 gem tests passed"
