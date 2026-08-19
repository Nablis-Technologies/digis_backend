# frozen_string_literal: true

module Reconciliation
  # Enqueues domain-owned reconciliation workers without reading or mutating
  # business records. Fast and slow groups let provider uncertainty be checked
  # promptly while payout and projection audits avoid unnecessary polling.
  class SupervisorJob < ApplicationJob
    queue_as :maintenance
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    FAST_JOBS = [ OutboxJob, PaymentAttemptsJob, RefundsJob ].freeze
    SLOW_JOBS = [ OrganizerPayoutsJob, SellerPayoutsJob, CredentialProjectionJob ].freeze
    JOBS = (FAST_JOBS + SLOW_JOBS).freeze
    GROUPS = { "all" => JOBS, "fast" => FAST_JOBS, "slow" => SLOW_JOBS }.freeze

    def perform(group = "all")
      GROUPS.fetch(group.to_s, JOBS).each(&:perform_later)
    end
  end
end
