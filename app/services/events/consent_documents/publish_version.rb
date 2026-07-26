# frozen_string_literal: true

module Events
  module ConsentDocuments
    # Publishes the current draft version of a consent document. Locks the
    # document, retires any previously published version, promotes the draft to
    # published with a canonical SHA-256 digest, records durable audit evidence,
    # and is idempotent when already published.
    class PublishVersion < Core::BaseService
      def initialize(consent_document:, actor:)
        @consent_document = consent_document
        @actor = actor
      end

      def call
        Events::ConsentDocument.transaction do
          consent_document.with_lock do
            draft = consent_document.versions.draft.lock.first
            if draft.nil?
              published = consent_document.versions.published.first
              return success(published) if published

              return failure(no_draft_error)
            end

            consent_document.versions.published.update_all(status: "retired")

            digest = ConsentDocumentVersion.content_sha256_for(
              type: consent_document.type,
              title: draft.title,
              body: draft.body
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
        failure Core::BusinessError.new(
          I18n.t("consent_document.errors.publish"),
          code: "invalid_consent_version",
          status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        )
      end

      private

      attr_reader :consent_document, :actor

      def no_draft_error
        Core::BusinessError.new(
          I18n.t("consent_document.errors.no_draft"),
          code: "no_draft",
          status: :unprocessable_entity
        )
      end

      def record_audit(version)
        Core::Audit::Record.call(
          audit_key: "event-consent-publish-#{version.id}",
          action: "event.consent.published",
          auditable_type: "Events::ConsentDocument",
          auditable_id: consent_document.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          audited_changes: { version: version.version, status: [ "draft", "published" ] },
          metadata: { version_id: version.id }
        )
      end
    end
  end
end
