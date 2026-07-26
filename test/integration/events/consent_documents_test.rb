# frozen_string_literal: true

require "test_helper"

module Events
  class ConsentDocumentsIntegrationTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    def setup
      @event = events_events(:ready_listing)
    end

    def create_document(body: "Be nice.", name: "Terms", type: "terms", title: "Attendee Terms")
      post "/events/#{@event.id}/consent_documents",
           params: { consent_document: { name: name, type: type, title: title, body: body } },
           headers: owner_headers, as: :json
    end

    test "manager can create a draft consent document with a draft version" do
      assert_difference -> { Events::ConsentDocument.count }, 1 do
        create_document
      end
      assert_response :created
      doc = Events::ConsentDocument.last
      assert_equal 1, doc.versions.draft.count
      assert_equal "Be nice.", doc.versions.draft.first.body
    end

    test "manager can publish the draft version" do
      create_document
      doc = Events::ConsentDocument.last

      post "/events/#{@event.id}/consent_documents/#{doc.id}/publish", headers: owner_headers, as: :json

      assert_response :ok
      assert_equal 1, doc.reload.versions.published.count
    end

    test "outsider cannot create a consent document" do
      post "/events/#{@event.id}/consent_documents",
           params: { consent_document: { name: "X", type: "terms", title: "t", body: "b" } },
           headers: user_headers, as: :json
      assert_response :forbidden
    end

    test "outsider cannot publish" do
      create_document
      doc = Events::ConsentDocument.last
      post "/events/#{@event.id}/consent_documents/#{doc.id}/publish", headers: user_headers, as: :json
      assert_response :forbidden
    end

    test "public scope excludes draft and retired versions" do
      create_document
      doc = Events::ConsentDocument.last
      post "/events/#{@event.id}/consent_documents/#{doc.id}/publish", headers: owner_headers, as: :json

      patch "/events/#{@event.id}/consent_documents/#{doc.id}",
            params: { consent_document: { body: "Updated terms." } },
            headers: owner_headers, as: :json
      assert_response :ok

      post "/events/#{@event.id}/consent_documents/#{doc.id}/publish", headers: owner_headers, as: :json
      assert_response :ok

      published = doc.reload.versions.published
      assert_equal 1, published.count
      assert published.none? { |v| v.status == "draft" || v.status == "retired" }
      assert_equal 1, doc.versions.retired.count
    end

    test "manager can activate an inactive consent document" do
      create_document
      doc = Events::ConsentDocument.last
      doc.update!(active: false)

      post "/events/#{@event.id}/consent_documents/#{doc.id}/activate", headers: owner_headers, as: :json

      assert_response :ok
      assert doc.reload.active?
    end

    test "manager can deactivate a consent document" do
      create_document
      doc = Events::ConsentDocument.last

      post "/events/#{@event.id}/consent_documents/#{doc.id}/deactivate", headers: owner_headers, as: :json

      assert_response :ok
      assert_not doc.reload.active?
    end

    test "outsider cannot activate" do
      create_document
      doc = Events::ConsentDocument.last
      post "/events/#{@event.id}/consent_documents/#{doc.id}/activate", headers: user_headers, as: :json
      assert_response :forbidden
    end

    test "outsider cannot deactivate" do
      create_document
      doc = Events::ConsentDocument.last
      post "/events/#{@event.id}/consent_documents/#{doc.id}/deactivate", headers: user_headers, as: :json
      assert_response :forbidden
    end

    test "cannot delete a published consent document (must deactivate)" do
      create_document
      doc = Events::ConsentDocument.last
      post "/events/#{@event.id}/consent_documents/#{doc.id}/publish", headers: owner_headers, as: :json
      assert_equal 1, doc.reload.versions.published.count

      delete "/events/#{@event.id}/consent_documents/#{doc.id}", headers: owner_headers, as: :json

      assert_response :unprocessable_entity
      assert Events::ConsentDocument.exists?(doc.id)
    end

    test "can delete a draft-only consent document" do
      create_document
      doc = Events::ConsentDocument.last
      assert_equal 0, doc.versions.published.count

      delete "/events/#{@event.id}/consent_documents/#{doc.id}", headers: owner_headers, as: :json

      assert_response :ok
      assert_not Events::ConsentDocument.exists?(doc.id)
    end
  end
end
