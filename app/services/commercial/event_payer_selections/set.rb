# frozen_string_literal: true

module Commercial
  module EventPayerSelections
    # Sets the current payer projection for one event/component pair. The
    # projection may change only through this command; every change receives
    # its own audit and outbox evidence while the row remains easy to read at
    # quote time.
    class Set < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(event:, fee_component:, charged_to:, selected_by: nil, idempotency_key:)
        @event = event
        @fee_component = fee_component
        @charged_to = charged_to.to_s.strip.downcase
        @selected_by = selected_by
        @idempotency_key = idempotency_key
      end

      def call
        prepare_request!
        ActiveRecord::Base.transaction do
          event = authoritative_event
          component = authoritative_component
          return failure(volume_error(:record_not_found)) unless event && component
          return failure(volume_error(:selection_event_mismatch)) unless component_belongs_to_event?(component, event)
          return failure(volume_error(:invalid_payer)) unless EventPayerSelection::PAYERS.include?(charged_to)
          return failure(volume_error(:payer_selection_forbidden)) unless payer_permitted?(component)

          set_locked_selection!(event, component)
        end
      rescue ArgumentError
        failure(
          Core::BusinessError.new(
            I18n.t("commercial.governance.errors.invalid_idempotency_key"),
            code: "invalid_idempotency_key", status: :unprocessable_entity
          )
        )
      rescue Core::Error => error
        failure(error)
      rescue ActiveRecord::RecordInvalid => error
        failure(
          Core::BusinessError.new(
            I18n.t("commercial.governance.errors.invalid_record"),
            code: "invalid_record", status: :unprocessable_entity,
            errors: error.record.errors.to_hash
          )
        )
      end

      private

      attr_reader :event, :fee_component, :charged_to, :selected_by, :idempotency_key,
        :key_digest, :request_fingerprint

      def prepare_request!
        @idempotency_key = normalize_idempotency_key(idempotency_key)
        @key_digest = idempotency_digest("event-payer-selection", @idempotency_key)
        @request_fingerprint = fingerprint_for(
          action: "set", event_id:, fee_component_id:, charged_to:
        )
      end

      def event_id
        event.respond_to?(:id) ? event.id : event.presence
      end

      def fee_component_id
        fee_component.respond_to?(:id) ? fee_component.id : fee_component.presence
      end

      def authoritative_event
        Events::Event.lock.find_by(id: event_id)
      end

      def authoritative_component
        Commercial::FeeComponent.includes(:event_product).find_by(id: fee_component_id)
      end

      def component_belongs_to_event?(component, authoritative_event)
        component.event_product_id.blank? || component.event_product.event_id == authoritative_event.id
      end

      def payer_permitted?(component)
        charged_to == component.charged_to || component.organizer_payer_choice
      end

      def set_locked_selection!(authoritative_event, component)
        audit_key = "commercial-event-payer-selection-#{authoritative_event.id}-#{component.id}-#{key_digest}"
        replay = replay_status(
          audit_key:, actor: selected_by, fingerprint: request_fingerprint
        )
        existing = Commercial::EventPayerSelection.lock.find_by(
          event_id: authoritative_event.id, fee_component_id: component.id
        )
        return success(existing) if replay == :replay && existing
        return failure(volume_error(:idempotency_conflict)) if replay == :conflict

        before = existing&.attributes&.slice("charged_to", "selected_by_id", "selected_at") || {}
        selection = existing || Commercial::EventPayerSelection.new(
          event: authoritative_event, fee_component: component
        )
        selection.assign_attributes(
          charged_to:, selected_by:, selected_at: Time.current,
          idempotency_key_digest: key_digest,
          request_fingerprint:
        )
        selection.save!
        record_transition!(
          target: selection,
          actor: selected_by,
          audit_key:,
          action: "commercial.event_payer_selection.set",
          audited_changes: before.merge(
            "charged_to" => [ before["charged_to"], charged_to ],
            "selected_by_id" => [ before["selected_by_id"], selection.selected_by_id ],
            "selected_at" => [ before["selected_at"], selection.selected_at ]
          ),
          metadata: {
            "request_fingerprint" => request_fingerprint,
            "idempotency_key_digest" => key_digest
          },
          topic: "commercial",
          event_type: "commercial.event_payer_selection.set",
          payload: {
            event_payer_selection_id: selection.id,
            event_id: selection.event_id,
            fee_component_id: selection.fee_component_id,
            charged_to: selection.charged_to
          }
        )
        success(selection)
      end

      def volume_error(key)
        Core::BusinessError.new(
          I18n.t("commercial.volume.errors.#{key}"),
          code: key.to_s, status: :unprocessable_entity
        )
      end
    end
  end
end
