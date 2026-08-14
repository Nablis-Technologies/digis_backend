# frozen_string_literal: true

module Commercial
  # Applies due version expiry through the same locked Commercial lifecycle
  # evidence boundary used by administrative commands. Re-running the job is
  # safe because terminal versions are not selected again.
  class ExpireScheduledStateJob < ApplicationJob
    queue_as :default
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    def perform(at: Time.current)
      result = Commercial::Versions::Expire.call(now: at)
      raise result.error if result.failure?

      result.value
    end
  end
end
