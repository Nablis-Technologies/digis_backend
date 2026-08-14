# frozen_string_literal: true

module Ticketing
  module Admissions
    # Evaluates admission eligibility from rows that the caller has already
    # locked. Keeping locking outside this policy lets online consumption and
    # later upload reconciliation share the same bounded/unlimited rules.
    class UsagePolicy
      def initialize(admission_slots:, product_access:, locked_uses:)
        @admission_slots = admission_slots
        @usage_limit = product_access.usage_limit
        @uses_by_slot = locked_uses.group_by(&:admission_slot_id)
      end

      def eligible?
        @admission_slots.all? do |slot|
          @usage_limit.nil? || active_use_count(slot) < @usage_limit
        end
      end

      def active_use_count(slot)
        uses_for(slot).count { |use| use.reversal.nil? }
      end

      def next_usage_number(slot)
        uses_for(slot).map(&:usage_number).max.to_i + 1
      end

      private

      def uses_for(slot)
        @uses_by_slot.fetch(slot.id, [])
      end
    end
  end
end
