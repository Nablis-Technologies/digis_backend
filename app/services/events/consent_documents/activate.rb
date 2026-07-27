# frozen_string_literal: true

module Events
  module ConsentDocuments
    # Activates a consent document, flipping the operational on/off switch so it
    # becomes eligible to be required at checkout (paired with a published
    # version). Idempotent and audited.
    class Activate < Core::BaseService
      def initialize(consent_document:, actor:)
        @consent_document = consent_document
        @actor = actor
      end

      def call
        return success(consent_document) if consent_document.active?

        ActiveRecord::Base.transaction do
          consent_document.update!(active: true)
          record_audit
          success(consent_document)
        end
      rescue ActiveRecord::RecordInvalid => error
        failure Core::BusinessError.new(
          I18n.t("consent_document.errors.activate"),
          code: "invalid_consent_document",
          status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        )
      end

      private

      attr_reader :consent_document, :actor

      def record_audit
        Core::Audit::Record.call(
          audit_key: "event-consent-activate-#{consent_document.id}",
          action: "event.consent.activated",
          auditable_type: "Events::ConsentDocument",
          auditable_id: consent_document.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          audited_changes: { active: [ false, true ] },
          metadata: {}
        )
      end
    end
  end
end
