# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# The optional SQLite backend is installed separately (docs/running.md).
group :development do
  # The ratchet on Sandi Metz's rules. Not on RubyGems yet, so it comes from git at a full commit id.
  gem "sandi", git: "https://github.com/mculp/sandi", ref: "c6f3250896a93db1517de9cda6a00ba5efabfd8d"
  # The baseline's counts are this version's.
  gem "rubocop", "1.87.0"
end
