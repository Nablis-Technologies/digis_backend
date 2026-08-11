# frozen_string_literal: true

require "test_helper"

module Events
  # Exercises the DB-level immutability trigger on consent document versions.
  # AR callbacks/validations are bypassed via update_all / raw SQL so we prove
  # the storage-layer guarantee holds even for non-ActiveRecord writers.
  class ConsentDocumentVersionImmutabilityTest < ActiveSupport::TestCase
    setup do
      @doc = Events::ConsentDocument.create!(
        event: events_events(:ready_listing),
        name: "Terms",
        type: "terms",
        created_by: core_users(:super_admin)
      )
    end

    def published_version
      @doc.versions.create!(
        version: 1, title: "Terms", body: "Original body",
        content_sha256: Events::ConsentDocumentVersion.content_sha256_for(
          type: "terms", title: "Terms", body: "Original body"),
        status: "published", published_by: core_users(:super_admin), published_at: Time.current,
        created_by: core_users(:super_admin)
      )
    end

    test "published consent version rejects column changes at the DB layer" do
      v = published_version
      assert_raises(ActiveRecord::StatementInvalid) do
        Events::ConsentDocumentVersion.where(id: v.id).update_all(body: "tampered")
      end
    end

    test "published consent version cannot be deleted at the DB layer" do
      v = published_version
      assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.lease_connection.execute(
          "DELETE FROM events_consent_document_versions WHERE id = '#{v.id}'")
      end
    end

    test "draft consent version may still be edited" do
      v = @doc.versions.create!(
        version: 2, title: "Draft", body: "Draft body",
        content_sha256: Events::ConsentDocumentVersion.content_sha256_for(
          type: "terms", title: "Draft", body: "Draft body"),
        status: "draft", created_by: core_users(:super_admin)
      )
      assert_nothing_raised do
        Events::ConsentDocumentVersion.where(id: v.id).update_all(body: "edited")
      end
      assert_equal "edited", v.reload.body
    end

    test "forward status transition (publish -> retire) is permitted" do
      v = published_version
      assert_nothing_raised do
        Events::ConsentDocumentVersion.where(id: v.id).update_all(status: "retired")
      end
      assert_equal "retired", v.reload.status
    end

    test "database requires publication metadata when publishing a draft" do
      v = @doc.versions.create!(
        version: 4, title: "Draft", body: "Draft body",
        content_sha256: Events::ConsentDocumentVersion.content_sha256_for(
          type: "terms", title: "Draft", body: "Draft body"
        ),
        status: "draft", created_by: core_users(:super_admin)
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Events::ConsentDocumentVersion.transaction(requires_new: true) do
          Events::ConsentDocumentVersion.where(id: v.id).update_all(status: "published")
        end
      end
      assert_nothing_raised do
        Events::ConsentDocumentVersion.where(id: v.id).update_all(
          status: "published", published_by_id: core_users(:super_admin).id, published_at: Time.current
        )
      end
    end

    test "retired consent version cannot regress or change content at the DB layer" do
      v = published_version
      Events::ConsentDocumentVersion.where(id: v.id).update_all(status: "retired")

      assert_raises(ActiveRecord::StatementInvalid) do
        Events::ConsentDocumentVersion.where(id: v.id).update_all(status: "draft")
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        Events::ConsentDocumentVersion.where(id: v.id).update_all(body: "tampered")
      end
    end

    test "draft consent version may be deleted at the DB layer" do
      v = @doc.versions.create!(
        version: 3, title: "Draft", body: "Draft body",
        content_sha256: Events::ConsentDocumentVersion.content_sha256_for(
          type: "terms", title: "Draft", body: "Draft body"),
        status: "draft", created_by: core_users(:super_admin)
      )
      assert_nothing_raised do
        ActiveRecord::Base.lease_connection.execute(
          "DELETE FROM events_consent_document_versions WHERE id = '#{v.id}'")
      end
    end
  end
end
