# frozen_string_literal: true

module Ticketing
  # Stores only digest-based request identity for scanner lifecycle commands.
  # Plaintext scanner tokens never enter this table or any replay record.
  class ScannerDeviceIdempotency < Ticketing::ApplicationRecord
    self.table_name = "ticketing_scanner_device_idempotencies"

    OPERATIONS = %w[revoke].freeze

    belongs_to :scanner_device, class_name: "Ticketing::ScannerDevice"

    validates :scanner_device, :operation, :idempotency_key_digest, :request_digest, presence: true
    validates :operation, inclusion: { in: OPERATIONS }
    validates :idempotency_key_digest, :request_digest,
              format: { with: /\A[0-9a-f]{64}\z/ }
  end
end
