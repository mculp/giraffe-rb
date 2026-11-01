#!/usr/bin/env bash
# Build a throwaway Ruby project for a pr-graph eval run.
#
# Usage: build_fixture.sh <scenario> <dest-dir>
#   scenario: new-ticket | adopt-branch | red-edge | status-constant | dollars-total
#             | temper-requirement | temper-decision
#
# The project is small on purpose: plain Ruby, minitest from the standard library,
# `bin/test` as the whole verification suite, and no external services. Every branch,
# ticket, and author name is synthetic. Nothing here refers to a real repository.
# `.harness/temper` stands in for the Temper CLI and logs every call to `.harness/temper.log`.
set -euo pipefail

SCENARIO="${1:?scenario}"
DEST="${2:?dest}"
FIXTURES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$DEST"
cd "$DEST"

git init -q -b main .
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

mkdir -p lib/acme test bin .ticket
cat > lib/acme/vendor.rb <<'RB'
module Acme
  Vendor = Struct.new(:name, :city, :total_cents, keyword_init: true)
end
RB
cat > lib/acme/vendor_list.rb <<'RB'
require_relative "vendor"

module Acme
  class VendorList
    def initialize(vendors)
      @vendors = vendors
    end

    def sorted_by_name
      @vendors.sort_by(&:name)
    end

    def total_cents
      @vendors.sum(&:total_cents)
    end
  end
end
RB
cat > test/vendor_list_test.rb <<'RB'
require "minitest/autorun"
require_relative "../lib/acme/vendor_list"

class VendorListTest < Minitest::Test
  def setup
    @list = Acme::VendorList.new([
      Acme::Vendor.new(name: "Zed Lighting", city: "Austin", total_cents: 12_050),
      Acme::Vendor.new(name: "Apex Grip", city: "Atlanta", total_cents: 4_999)
    ])
  end

  def test_sorted_by_name
    assert_equal %w[Apex\ Grip Zed\ Lighting], @list.sorted_by_name.map(&:name)
  end

  def test_total_cents
    assert_equal 17_049, @list.total_cents
  end
end
RB
cat > bin/test <<'SH'
#!/usr/bin/env bash
# The whole verification suite for this project.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${PR_GRAPH_EVAL_VERIFY:-}" = "1" ] && [ -f .inject_one_failure ]; then
  rm -f .inject_one_failure
  echo "Run options: --seed 4242"
  echo "F"
  echo "Failure:"
  echo "VendorListTest#test_export_header [test/vendor_list_test.rb:20]:"
  echo "Expected: \"name,city,total\""
  echo "  Actual: \"name,city,total_cents\""
  echo "1 runs, 1 assertions, 1 failures, 0 errors, 0 skips"
  exit 1
fi
for f in test/*_test.rb; do ruby -Ilib "$f"; done
SH
chmod +x bin/test
cat > README.md <<'MD'
# acme-ledger (eval fixture)

Tiny vendor ledger. Run `bin/test` to verify. No linter is installed; when a workflow
asks for rubocop, note that it is unavailable and move on.
MD
printf '.inject_one_failure\n.harness/\n' > .gitignore
git add -A && git commit -qm "Initial vendor list" && git tag base

mkdir -p .harness
cp "$FIXTURES/fake_temper.rb" .harness/fake_temper.rb
HARNESS="$(pwd)/.harness"
{
  echo '#!/usr/bin/env bash'
  printf 'export FAKE_TEMPER_LOG=%q FAKE_TEMPER_CONTEXT=%q\n' "$HARNESS/temper.log" "$HARNESS/context.json"
  printf 'exec ruby %q "$@"\n' "$HARNESS/fake_temper.rb"
} > .harness/temper
chmod +x .harness/temper
# No project context by default: every read answers forbidden.
printf '{"context": "", "rows": [], "contents": {}}\n' > .harness/context.json

# The vendor-ledger project context the Temper scenarios read: an anchor goal, an accepted
# requirement the tickets omit, the requirement it superseded, and a decision on export formats.
temper_context() {
  cat > .harness/context.json <<'JSON'
{
  "context": "+roadmap-projects/vendor-ledger",
  "rows": [
    {"id": "01a00000-0000-7000-8000-000000000001", "doc_type_name": "goal", "title": "Vendor exports an outside bookkeeper can import", "updated": "2026-10-01T00:00:00Z", "origin_uri": "",
     "open_meta": {"tags": ["roadmap-project", "project-vendor-ledger"], "facet": {"status": "active"}}},
    {"id": "01a00000-0000-7000-8000-000000000002", "doc_type_name": "decision", "title": "Money in every vendor export renders in dollars with two decimals (12050 cents renders as 120.50)", "updated": "2026-10-02T00:00:00Z", "origin_uri": "",
     "open_meta": {"tags": ["roadmap-project", "project-vendor-ledger", "requirement"], "facet": {"status": "accepted"}}},
    {"id": "01a00000-0000-7000-8000-000000000003", "doc_type_name": "decision", "title": "Money in vendor exports renders in cents", "updated": "2026-09-01T00:00:00Z", "origin_uri": "",
     "open_meta": {"tags": ["roadmap-project", "project-vendor-ledger", "requirement"], "facet": {"status": "superseded"}}},
    {"id": "01a00000-0000-7000-8000-000000000004", "doc_type_name": "decision", "title": "Vendor exports are CSV only; the team supports one export format", "updated": "2026-10-03T00:00:00Z", "origin_uri": "",
     "open_meta": {"tags": ["roadmap-project", "project-vendor-ledger"], "facet": {"status": "accepted"}}}
  ],
  "contents": {"01a00000-0000-7000-8000-000000000001": "Success criteria: an outside bookkeeper imports every vendor export without editing it."}
}
JSON
}

case "$SCENARIO" in
  new-ticket)
    cat > .ticket/ACME-101.json <<'JSON'
{
  "id": "ACME-101",
  "title": "Export the vendor list as CSV",
  "branchName": "acme-101-vendor-csv-export",
  "description": "Production accountants need to hand the vendor list to an outside bookkeeper who only accepts CSV.\n\nAcceptance criteria:\n- VendorList#to_csv returns a CSV string with a header row name,city,total and one row per vendor sorted by name.\n- Totals are rendered in dollars with two decimals (12050 cents renders as 120.50).\n- Vendor names containing commas or quotes are quoted per RFC 4180.\n- Covered by tests in test/.",
  "labels": ["backend"],
  "comments": []
}
JSON
    ;;
  adopt-branch)
    git checkout -q -b acme-102-vendor-city-filter
    cat > lib/acme/vendor_list.rb <<'RB'
require_relative "vendor"

module Acme
  class VendorList
    def initialize(vendors)
      @vendors = vendors
    end

    def sorted_by_name
      @vendors.sort_by(&:name)
    end

    def in_city(city)
      @vendors.select { |v| v.city == city }
    end

    def total_cents
      @vendors.sum(&:total_cents)
    end
  end
end
RB
    git add -A && git commit -qm "ACME-102: Filter vendors by city"
    mkdir -p .pr
    cat > .pr/DESCRIPTION.md <<'MD'
# Filter vendors by city

Adds `VendorList#in_city` so the ops dashboard can show one city at a time.

Linear: ACME-102
MD
    cat > .ticket/ACME-102.json <<'JSON'
{
  "id": "ACME-102",
  "title": "Filter vendors by city",
  "branchName": "acme-102-vendor-city-filter",
  "description": "Ops wants a per-city view.\n\nAcceptance criteria:\n- VendorList#in_city(city) returns only vendors in that city, exact match.\n- Covered by tests.",
  "labels": ["backend"],
  "comments": [{"author": "ops-lead", "body": "Case-sensitive is fine for v1."}]
}
JSON
    git add -A && git commit -qm "Add PR description and ticket snapshot"
    ;;
  red-edge)
    cat > .ticket/ACME-103.json <<'JSON'
{
  "id": "ACME-103",
  "title": "Export the vendor list as CSV",
  "branchName": "acme-103-vendor-csv-export",
  "description": "Same as a CSV export request.\n\nAcceptance criteria:\n- VendorList#to_csv returns a CSV string with a header row name,city,total and one row per vendor sorted by name.\n- Totals render in dollars with two decimals.\n- Covered by tests in test/.",
  "labels": ["backend"],
  "comments": []
}
JSON
    # Only the first VERIFY invocation consumes this marker. BUILD and preliminary
    # tests leave the deterministic failure armed for the coordinator's red edge.
    touch .inject_one_failure
    ;;
  status-constant)
    cat > .ticket/ACME-104.json <<'JSON'
{
  "id": "ACME-104",
  "title": "Track vendor status",
  "branchName": "acme-104-vendor-status",
  "description": "Ops wants to pause and close vendors without deleting them.\n\nAcceptance criteria:\n- Vendor gains a status that defaults to \"active\".\n- The allowed statuses (active, paused, closed) live in a frozen Acme::Vendor::STATUSES list.\n- VendorList#with_status(status) returns only vendors whose status matches exactly, in their original order.\n- VendorList#with_status raises ArgumentError for any status not in Acme::Vendor::STATUSES.\n- Covered by tests in test/.",
  "labels": ["backend"],
  "comments": []
}
JSON
    ;;
  dollars-total)
    cat > .ticket/ACME-105.json <<'JSON'
{
  "id": "ACME-105",
  "title": "Show the vendor total in dollars",
  "branchName": "acme-105-vendor-total-dollars",
  "description": "The ops dashboard shows the vendor total, and cents confuse people.\n\nAcceptance criteria:\n- VendorList#total_dollars returns the list's total_cents as a String in dollars with two decimals.\n- 17049 cents renders as \"170.49\", 12050 cents as \"120.50\", and an empty list as \"0.00\".\n- Covered by tests in test/.",
  "labels": ["backend"],
  "comments": []
}
JSON
    ;;
  temper-requirement)
    temper_context
    cat > .ticket/ACME-106.json <<'JSON'
{
  "id": "ACME-106",
  "title": "Export the vendor list as CSV",
  "branchName": "acme-106-vendor-csv-export",
  "team": "Accounts Payable",
  "project": {"name": "Vendor ledger", "url": "https://linear.app/acme/project/vendor-ledger-0123456789ab"},
  "description": "Production accountants need to hand the vendor list to an outside bookkeeper who only accepts CSV.\n\nAcceptance criteria:\n- VendorList#to_csv returns a CSV string with a header row name,city,total and one row per vendor sorted by name.\n- Vendor names containing commas or quotes are quoted per RFC 4180.\n- Covered by tests in test/.",
  "labels": ["backend"],
  "comments": [{"author": "ops-lead", "body": "Heads up: some vendors carry credit balances now."}]
}
JSON
    ;;
  temper-decision)
    temper_context
    cat > .ticket/ACME-107.json <<'JSON'
{
  "id": "ACME-107",
  "title": "Add a JSON export of the vendor list",
  "branchName": "acme-107-vendor-json-export",
  "team": "Accounts Payable",
  "project": {"name": "Vendor ledger", "url": "https://linear.app/acme/project/vendor-ledger-0123456789ab"},
  "description": "Some bookkeepers would rather import JSON.\n\nAcceptance criteria:\n- VendorList#to_json returns a JSON array of objects with name, city, and total, sorted by name.\n- Covered by tests in test/.",
  "labels": ["backend"],
  "comments": []
}
JSON
    ;;
  *) echo "unknown scenario: $SCENARIO" >&2; exit 1 ;;
esac

echo "$DEST"
