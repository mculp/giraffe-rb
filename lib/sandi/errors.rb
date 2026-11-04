# frozen_string_literal: true

module Sandi
  # The ratchet could not measure at all, which is not the same as a measurement that came out worse.
  class Error < StandardError; end
end
