# frozen_string_literal: true

require "json"

module PrGraph
  # The checks a record must pass before it leaves the machine: a size cap and a scan for secrets. The run
  # record withholds what fails them; the run store refuses to write it.
  module ContentScan
    MAX_BYTES = 1_000_000
    SECRET = Regexp.union(
      /(?:AKIA|ASIA)[0-9A-Z]{16}/, /gh[pousr]_[A-Za-z0-9]{36,}/, /github_pat_\w{22,}/, /xox[abposr]-[A-Za-z0-9-]{10,}/,
      /sk-ant-[\w-]{20,}/, /[sr]k_live_[A-Za-z0-9]{16,}/, /lin_api_[A-Za-z0-9]{32,}/, /bkua_[A-Za-z0-9]{32,}/,
      /AIza[\w-]{35}/, /-----BEGIN [A-Z ]*PRIVATE KEY-----/
    )

    module_function

    # Why content may not leave, or nil. `json` is the content serialized, which the size is measured on.
    def violation(content, json)
      if json.bytesize > MAX_BYTES then "it is larger than #{MAX_BYTES / 1_000_000} MB"
      elsif texts(content).any? { |text| text.match?(SECRET) } then "it matches a secret pattern"
      end
    end

    # Checks unescaped strings: JSON escapes a newline to `\n`, which hides the token after it from `\b`.
    def texts(value)
      case value
      when Hash then value.flat_map { |key, inner| [key.to_s, *texts(inner)] }
      when Array then value.flat_map { |inner| texts(inner) }
      else [value.to_s]
      end
    end
  end
end
