# frozen_string_literal: true

module PrGraph
  # Stops a process started with `pgroup: true` and whatever it spawned: TERM, a moment to exit, then KILL.
  module ProcessGroup
    module_function

    def terminate(pid)
      Process.kill("TERM", -pid)
      sleep 0.05
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
