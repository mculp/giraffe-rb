#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ruby tests/spec_command_test.rb
