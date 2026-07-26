# frozen_string_literal: true

require "test_helper"

module Events
  module ConsentDocuments
    class PublishVersionTest < ActiveSupport::TestCase
      def setup
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
      end

      def build_document(type: "terms", name: "Terms of Entry")
        doc = Events::ConsentDocument.create!(
          event: @event, created_by: @actor, type: type, name: name, active: true
        )
        doc.versions.create!(
          version: 1,
          status: "draft",
          title: "Attendee Terms",
          body: "Be nice.",
          content_sha256: Events::ConsentDocumentVersion.content_sha256_for(
            type: type, title: "Attendee Terms", body: "Be nice."
          ),
          acceptance_scope: "buyer",
          required: true,
          created_by: @actor
        )
        doc
      end

      test "publishes the draft and leaves exactly one published version" do
        doc = build_document

        result = Events::ConsentDocuments::PublishVersion.call(consent_document: doc, actor: @actor)

        assert result.success?, result.error.inspect
        assert_equal 1, doc.versions.published.count
        assert_equal 1, doc.versions.published.first.version
      end

      test "monotonic version numbers across republishes" do
        doc = build_document
        Events::ConsentDocuments::PublishVersion.call(consent_document: doc, actor: @actor)
        assert_equal 1, doc.versions.published.first.version

        doc.versions.create!(
          version: 2,
          status: "draft",
          title: "Attendee Terms",
          body: "Updated terms.",
          content_sha256: Events::ConsentDocumentVersion.content_sha256_for(
            type: "terms", title: "Attendee Terms", body: "Updated terms."
          ),
          acceptance_scope: "buyer",
          required: true,
          created_by: @actor
        )
        Events::ConsentDocuments::PublishVersion.call(consent_document: doc, actor: @actor)

        assert_equal 1, doc.versions.published.count
        assert_equal 2, doc.versions.published.first.version
        assert_equal 1, doc.versions.retired.count
        assert_equal 1, doc.versions.retired.first.version
      end

      test "computes canonical SHA-256 content digest" do
        doc = build_document
        Events::ConsentDocuments::PublishVersion.call(consent_document: doc, actor: @actor)

        version = doc.versions.published.first
        expected = Events::ConsentDocumentVersion.content_sha256_for(
          type: doc.type, title: version.title, body: version.body
        )
        assert_equal expected, version.content_sha256
      end

      test "published version is immutable" do
        doc = build_document
        Events::ConsentDocuments::PublishVersion.call(consent_document: doc, actor: @actor)

        version = doc.versions.published.first
        version.body = "tampered"
        version.content_sha256 = "0" * 64
        assert_not version.valid?
        assert version.errors[:body].present?
        assert version.errors[:content_sha256].present?
      end

      test "publish is idempotent under replay (no duplicate version or audit)" do
        doc = build_document
        subject = -> { Events::ConsentDocuments::PublishVersion.call(consent_document: doc, actor: @actor) }

        assert_audit_idempotent(
          subject,
          action: "event.consent.published",
          auditable_type: "Events::ConsentDocument",
          auditable_id: doc.id
        )

        assert_equal 1, doc.reload.versions.published.count

        replay = Events::ConsentDocuments::PublishVersion.call(consent_document: doc, actor: @actor)
        assert replay.success?
        assert_equal doc.versions.published.first.id, replay.value.id
      end
    end
  end
end
