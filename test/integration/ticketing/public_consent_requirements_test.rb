# frozen_string_literal: true

require "test_helper"

module Ticketing
  class PublicConsentRequirementsTest < ActionDispatch::IntegrationTest
    setup do
      @event = events_events(:ready_listing)
      @event.update_columns(status: "published", visibility: "public")
      @ticket_type = create_ticket_type("Public consent ticket")
      @other_ticket_type = create_ticket_type("Other consent ticket")
    end

    test "lists only applicable current active consent versions with review fields" do
      _event_document, event_version = create_document(scope: "buyer", required: true)
      _product_document, product_version = create_document(
        scope: "admission_slot", required: false, ticket_type: @ticket_type
      )
      create_document(scope: "buyer", required: true, ticket_type: @other_ticket_type)
      inactive_document, = create_document(scope: "buyer", required: true)
      inactive_document.update!(active: false)

      get "/public/events/#{@event.slug}/ticket_types/#{@ticket_type.id}/consent_requirements", as: :json

      assert_response :success
      requirements = response.parsed_body.fetch("data").index_by { |requirement| requirement.fetch("consent_document_version_id") }
      assert_equal [ event_version.id, product_version.id ].sort, requirements.keys.sort
      assert_equal(
        {
          "consent_document_version_id" => event_version.id,
          "document_version" => event_version.version,
          "title" => event_version.title,
          "body" => event_version.body,
          "content_sha256" => event_version.content_sha256,
          "required" => true,
          "acceptance_scope" => "buyer"
        },
        requirements.fetch(event_version.id)
      )
      requirements.each_value do |requirement|
        refute_includes requirement.keys, "created_by_id"
        refute_includes requirement.keys, "published_by_id"
        refute_includes requirement.keys, "signer_role"
        refute_includes requirement.keys, "registration_id"
        refute_includes requirement.keys, "evidence_digest"
      end
    end

    test "does not expose requirements for a non-public event" do
      @event.update_columns(visibility: "private")

      get "/public/events/#{@event.slug}/ticket_types/#{@ticket_type.id}/consent_requirements", as: :json

      assert_response :not_found
    end

    private

    def create_ticket_type(name)
      ticket_type = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name:, type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value.ticket_type
      ticket_type.event_product.update!(status: "active")
      ticket_type
    end

    def create_document(scope:, required:, ticket_type: nil)
      document = Events::ConsentDocument.create!(
        event: @event,
        name: "Public consent #{SecureRandom.hex(4)}",
        type: "terms",
        created_by: core_users(:super_admin)
      )
      version = document.versions.create!(
        version: 1,
        title: "Review these terms",
        body: "The exact consent content.",
        content_sha256: Events::ConsentDocumentVersion.content_sha256_for(
          type: document.type, title: "Review these terms", body: "The exact consent content."
        ),
        required:,
        acceptance_scope: scope,
        status: "draft",
        created_by: core_users(:super_admin)
      )
      version.update!(status: "published", published_by: core_users(:super_admin), published_at: Time.current)
      Events::ConsentDocumentProduct.create!(consent_document: document, ticket_type:) if ticket_type
      [ document, version ]
    end
  end
end
