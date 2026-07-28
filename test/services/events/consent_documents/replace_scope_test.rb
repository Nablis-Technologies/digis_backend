# frozen_string_literal: true

require "test_helper"

module Events
  module ConsentDocuments
    class ReplaceScopeTest < ActiveSupport::TestCase
      setup do
        @event_a = events_events(:ready_listing)
        @event_b = events_events(:draft_concert)

        @doc = Events::ConsentDocument.create!(
          event: @event_a, name: "Terms", type: "terms",
          created_by: core_users(:super_admin)
        )

        @same_event_product = Catalog::Products::Create.new(
          event: @event_a,
          attributes: { name: "VIP A", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed",
            admissions_per_unit: 1
          }
        ).call.value
        @same_event_tt = @same_event_product.ticket_type

        @other_event_product = Catalog::Products::Create.new(
          event: @event_b,
          attributes: { name: "VIP B", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed",
            admissions_per_unit: 1
          }
        ).call.value
        @other_event_tt = @other_event_product.ticket_type
      end

      test "replaces scope with the given ticket types" do
        result = Events::ConsentDocuments::ReplaceScope.new(
          consent_document: @doc,
          ticket_type_ids: [ @same_event_tt.id ]
        ).call
        assert result.success?
        assert_equal [ @same_event_tt.id ],
                     @doc.consent_document_products.pluck(:ticket_type_id).sort
      end

      test "empty list clears the scope (applies to all)" do
        Events::ConsentDocuments::ReplaceScope.new(
          consent_document: @doc, ticket_type_ids: [ @same_event_tt.id ]
        ).call
        result = Events::ConsentDocuments::ReplaceScope.new(
          consent_document: @doc, ticket_type_ids: []
        ).call
        assert result.success?
        assert_empty @doc.consent_document_products.reload
      end

      test "rejects a ticket type from a different event" do
        result = Events::ConsentDocuments::ReplaceScope.new(
          consent_document: @doc,
          ticket_type_ids: [ @other_event_tt.id ]
        ).call
        assert result.failure?
        assert_empty @doc.consent_document_products.reload
      end

      test "idempotent: running twice yields the same scope" do
        Events::ConsentDocuments::ReplaceScope.new(
          consent_document: @doc, ticket_type_ids: [ @same_event_tt.id ]
        ).call
        Events::ConsentDocuments::ReplaceScope.new(
          consent_document: @doc, ticket_type_ids: [ @same_event_tt.id ]
        ).call
        assert_equal 1, @doc.consent_document_products.reload.count
      end
    end
  end
end
