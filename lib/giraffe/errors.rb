# frozen_string_literal: true

module Giraffe
  class Error < StandardError
    # What a failed model call reported spending, when it got as far as reporting.
    attr_accessor :usage
  end
  # A model output the harness will not use. Resuming asks again rather than replaying it.
  class InvalidOutput < Error; end
  class PatchRejected < InvalidOutput; end
  class UnstorableContent < InvalidOutput; end
  # A command that ran past its time or output limit.
  class CommandLimit < Error; end
  # A spec that fails with no mutation applied, which is the candidate's fault rather than the auditor's.
  class BaselineFailed < Error; end
  class Parked < Error; end
  class Cancelled < Error; end
  class RunLocked < Error; end
end
