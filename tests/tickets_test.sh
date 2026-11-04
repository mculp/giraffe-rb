#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ruby tests/tickets_test.rb
