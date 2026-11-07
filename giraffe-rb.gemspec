# frozen_string_literal: true

require_relative "lib/giraffe/version"

Gem::Specification.new do |spec|
  # "giraffe" on RubyGems is another project (2010). Everything inside is Giraffe, so taking that name over is this
  # one line.
  spec.name = "giraffe-rb"
  spec.version = Giraffe::VERSION
  spec.authors = ["Matt Culpepper"]
  spec.summary = "Takes a change from a Linear ticket to a reviewed draft PR"
  spec.description = "A Ruby harness that runs every required step as code and calls a model only for judgment or " \
                     "for writing code, each call with a fresh context, a fixed tool list and a validated output schema."
  spec.homepage = "https://github.com/mculp/giraffe-rb"
  spec.required_ruby_version = ">= 3.4"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  # The library reads its prompts, schemas and contracts from beside lib/, and requires parts of scripts/.
  spec.files = Dir["lib/**/*.rb", "scripts/*.rb", "prompts/*.md", "schemas/*.json", "references/*", "bin/giraffe",
                   "README.md", "docs/*.md"]
  spec.bindir = "bin"
  spec.executables = ["giraffe"]

  spec.add_dependency "json_schemer", "~> 2.5"

  # The SQLite backend loads sqlite3 only when chosen (docs/running.md).
end
