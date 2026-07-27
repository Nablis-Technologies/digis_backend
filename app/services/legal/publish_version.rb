# frozen_string_literal: true

module Legal
  class PublishVersion < Core::BaseService
    def initialize(legal_document:, actor:)
      @legal_document = legal_document
      @actor = actor
    end

    def call
      legal_document.transaction do
        legal_document.with_lock do
          draft = legal_document.versions.draft.lock.first
          if draft.nil?
            published = legal_document.versions.published.first
            return success(published) if published

            return failure(
              Core::BusinessError.new(
                I18n.t("legal_document.errors.no_draft"),
                code: "no_draft", status: :unprocessable_entity
              )
            )
          end

          legal_document.versions.published.update_all(status: "retired")

          digest = Legal::LegalDocumentVersion.content_sha256_for(
            title: draft.title, body: draft.body
          )

          draft.update!(
            status: "published",
            content_sha256: digest,
            published_by: actor,
            published_at: Time.current
          )

          record_audit(draft)
          success(draft)
        end
      end
    rescue ActiveRecord::RecordInvalid => error
      failure(
        Core::BusinessError.new(
          I18n.t("legal_document.errors.publish"),
          code: "invalid_legal_version",
          status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        )
      )
    end

    private

    attr_reader :legal_document, :actor

    def record_audit(version)
      Core::Audit::Record.call(
        audit_key: "legal-publish-#{version.id}",
        action: "legal.published",
        auditable_type: "Legal::LegalDocument",
        auditable_id: version.legal_document_id,
        actor_type: actor.class.name,
        actor_id: actor.id,
        audited_changes: { version: version.version, status: %w[draft published] },
        metadata: { version_id: version.id }
      )
    end
  end
end
