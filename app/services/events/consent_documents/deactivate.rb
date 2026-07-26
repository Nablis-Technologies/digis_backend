# frozen_string_literal: true

module Events
  module ConsentDocuments
    # Deactivates a consent document, flipping the operational on/off switch so it
    # is no longer required at checkout while preserving the immutable published
    # version and its audit trail. Idempotent and audited.
    class Deactivate < Core::BaseService
      def initialize(consent_document:, actor:)
        @consent_document = consent_document
        @actor = actor
      end

      def call
        return success(consent_document) unless consent_document.active?

        ActiveRecord::Base.transaction do
          consent_document.update!(active: false)
          record_audit
          success(consent_document)
        end
      rescue ActiveRecord::RecordInvalid => error
        failure Core::BusinessError.new(
          I18n.t("consent_document.errors.deactivate"),
          code: "invalid_consent_document",
          status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        )
      end

      private

      attr_reader :consent_document, :actor

      def record_audit
        Core::Audit::Record.call(
          audit_key: "event-consent-deactivate-#{consent_document.id}",
          action: "event.consent.deactivated",
          auditable_type: "Events::ConsentDocument",
          auditable_id: consent_document.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          audited_changes: { active: [ true, false ] },
          metadata: {}
        )
      end
    end
  end
end
