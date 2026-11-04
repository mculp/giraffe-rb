#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ruby tests/steps_test.rb
