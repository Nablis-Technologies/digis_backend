# frozen_string_literal: true

module Ticketing
  module Registrations
    module AudienceProof
      # Shares proof association and idempotency-key parsing without conflating
      # release and reacquisition failure semantics.
      module Support
        module_function

        def proof_reference(registration:)
          code_id = registration.access_code_id
          invitation_id = registration.invitation_id
          return [ :inconsistent, nil ] if code_id.present? && invitation_id.present?
          return reference(:access_code, registration.access_code) if code_id.present?
          return reference(:invitation, registration.invitation) if invitation_id.present?
          return [ :public, nil ] if registration.ticket_type.audience == "public"

          [ :missing, nil ]
        end

        def transition_digest(value)
          Core::IdempotencyKey.new(value).digest
        rescue ArgumentError, NoMethodError
          nil
        end

        def reference(kind, record)
          record.present? ? [ kind, record ] : [ :missing, nil ]
        end
        private_class_method :reference
      end
    end
  end
end
