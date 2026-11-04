#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ruby tests/tool_profile_test.rb
