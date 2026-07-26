# frozen_string_literal: true

module Legal
  class Activate < Core::BaseService
    def initialize(legal_document:, actor:)
      @legal_document = legal_document
      @actor = actor
    end

    def call
      return success(legal_document) if legal_document.active?

      legal_document.transaction do
        legal_document.update!(active: true)
        record_audit
        success(legal_document)
      end
    rescue ActiveRecord::RecordInvalid => error
      failure Core::BusinessError.new(
        I18n.t("legal_document.errors.activate"),
        code: "invalid_legal_document",
        status: :unprocessable_entity,
        errors: error.record.errors.to_hash
      )
    end

    private

    attr_reader :legal_document, :actor

    def record_audit
      Core::Audit::Record.call(
        audit_key: "legal-activate-#{legal_document.id}",
        action: "legal.activated",
        auditable_type: "Legal::LegalDocument",
        auditable_id: legal_document.id,
        actor_type: actor.class.name,
        actor_id: actor.id,
        audited_changes: { active: [ false, true ] },
        metadata: {}
      )
    end
  end
end
