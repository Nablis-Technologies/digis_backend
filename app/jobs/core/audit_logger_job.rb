# frozen_string_literal: true

module Core
  # Dumb pipe: write the already-normalized payload through the single audit
  # writer. Retries are safe because audit_key is unique and replays return the
  # existing row. No record resolution or diffing happens here anymore.
  class AuditLoggerJob < ApplicationJob
    queue_as :audit
    retry_on StandardError, wait: 5.seconds, attempts: 3

    def perform(**payload)
      Core::Audit::Record.call(**payload).value
    end
  end
end
