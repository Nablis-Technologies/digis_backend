# frozen_string_literal: true

module Ticketing
  module PurchaseLimits
    # Reads the locked count used by reservation commands without exposing
    # allocation history to attendees.
    class Availability < Core::BaseService
      include Support

      Result = Data.define(:limit, :reserved, :committed, :available)

      def initialize(ticket_type:, user:, registration: nil, scope_event_date_id: nil)
        @ticket_type = ticket_type
        @user = user
        @registration = registration
        @scope_event_date_id = scope_event_date_id
      end

      def call
        scope_event_date_id = resolved_scope
        value = ActiveRecord::Base.transaction do
          lock_scope!(@ticket_type, scope_event_date_id, @user)
          release_expired!(scope_event_date_id)
          reserved = allocations.where(status: "reserved").count
          committed = allocations.where(status: "committed").count
          limit = effective_limit
          Result.new(limit:, reserved:, committed:, available: limit && [ limit - reserved - committed, 0 ].max)
        end
        success(value)
      rescue Support::BusinessFailure => error
        error.result
      end

      private

      attr_reader :ticket_type, :user, :registration, :scope_event_date_id

      def resolved_scope
        return scope_event_date_id if scope_event_date_id.present?
        return nil unless registration

        limit_scope_for(ticket_type, registration)
      end

      def allocations
        PurchaseLimitAllocation.where(ticket_type:, user:, scope_event_date_id:)
      end

      def release_expired!(scope_id)
        allocations.where(status: "reserved").where("expires_at <= ?", Time.current).lock.find_each do |allocation|
          allocation.update!(
            status: "released",
            expires_at: nil,
            released_at: Time.current,
            release_reason: "expired"
          )
        end
      end

      def effective_limit
        base = ticket_type.max_packages_per_user
        override = registration && PurchaseLimitOverride.find_by(registration_id: registration.id)
        return base if override.nil?
        return override.additional_packages if base.nil?

        base + override.additional_packages
      end
    end
  end
end
