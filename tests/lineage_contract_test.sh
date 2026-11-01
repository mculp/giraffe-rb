#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${SCRIPT_DIR}/../scripts"

tests=0

ok() {
  tests=$((tests + 1))
  echo "ok ${tests} - $1"
}

fail() {
  echo "not ok $((tests + 1)) - $1" >&2
  exit 1
}

ruby -I "$SCRIPTS" -r lineage_contract -e '
  lineage = PrGraph::LineageContract.new
  artifacts = PrGraph::ArtifactLog.new.contract.fetch("families").keys.sort
  abort unless lineage.version == 1
  abort unless lineage.contract.fetch("families").keys.sort == artifacts
  abort unless lineage.trigger_node == "BUILD"
  abort unless lineage.source_family == "build_manifest"
'
ok "covers every artifact family and derives invalidation from BUILD lineage"

ruby -I "$SCRIPTS" -r lineage_contract -e '
  lineage = PrGraph::LineageContract.new
  expected = %w[bot_feedback browser_review build_manifest ci_result description done_manifest publish_manifest self_review validation verification]
  actual = lineage.contract.fetch("families").keys.select { |family| lineage.candidate_dependent?(family) }.sort
  abort unless actual == expected
'
ok "classifies every candidate-sensitive artifact without a node allowlist"

if output=$(ruby -I "$SCRIPTS" -r lineage_contract -e '
  PrGraph::LineageContract.new.validate_artifact!("family" => "publish_manifest", "candidate_sha" => nil, "input_sha" => nil)
' 2>&1); then
  fail "missing candidate SHA was accepted"
fi
printf '%s' "$output" | grep -Fq "requires a full candidate SHA" || fail "missing-SHA error was hidden"
ok "rejects candidate-dependent evidence without an immutable Git SHA"

if output=$(ruby -I "$SCRIPTS" -r lineage_contract -e '
  PrGraph::LineageContract.new.validate_artifact!(
    "family" => "publish_manifest",
    "candidate_sha" => "1111111111111111111111111111111111111111",
    "input_sha" => "2222222222222222222222222222222222222222"
  )
' 2>&1); then
  fail "conflicting candidate lineage was accepted"
fi
printf '%s' "$output" | grep -Fq "must consume its candidate SHA" || fail "conflicting-lineage error was hidden"
ok "rejects non-BUILD evidence whose input and candidate identities conflict"

ruby -I "$SCRIPTS" -r lineage_contract -e '
  PrGraph::LineageContract.new.validate_artifact!("family" => "implementation_plan", "candidate_sha" => nil)
'
ok "preserves contract-declared SHA-independent planning artifacts"

if output=$(ruby -I "$SCRIPTS" -r lineage_contract -e '
  PrGraph::LineageContract.new.candidate_dependent?("undeclared")
' 2>&1); then
  fail "unknown family was accepted"
fi
printf '%s' "$output" | grep -Fq "unknown lineage family" || fail "unknown-family error was hidden"
ok "fails closed when a graph version introduces an undeclared artifact family"

echo "1..${tests}"
