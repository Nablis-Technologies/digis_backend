# frozen_string_literal: true

require "test_helper"

module Ticketing
  class SuspensionConcurrencyTest < ActionDispatch::IntegrationTest
    include Ticketing::PackageWorkflowTestHelpers

    self.use_transactional_tests = false

    setup do
      setup_package_workflow
    end

    teardown do
      next unless @ticket&.persisted?

      product_id = @product.id
      ticket_type_id = @product.ticket_type.id
      registration_id = @registration.id
      order_item_id = @ticket.order_item_id
      order_id = Orders::OrderItem.where(id: order_item_id).pick(:order_id)
      event_date_ids = Catalog::ProductAccess.where(event_product_id: product_id).distinct.pluck(:event_date_id)

      Ticketing::ApplicationRecord.transaction do
        Ticketing::CredentialClaim.where(
          credential_id: Ticketing::Credential.where(ticket_id: @ticket.id).select(:id)
        ).delete_all
        Ticketing::CredentialRevocation.where(
          credential_id: Ticketing::Credential.where(ticket_id: @ticket.id).select(:id)
        ).delete_all
        Ticketing::AttendeeIndexEntry.where(ticket_id: @ticket.id).delete_all
        Ticketing::Credential.where(ticket_id: @ticket.id).delete_all
        Ticketing::CredentialGeneration.where(ticket_id: @ticket.id).delete_all
        Ticketing::AdmissionSlot.where(ticket_id: @ticket.id).delete_all
        Ticketing::TicketTransfer.where(ticket_id: @ticket.id).delete_all
        Ticketing::TicketSuspension.where(ticket_id: @ticket.id).delete_all
        Ticketing::Revocation.where(ticket_id: @ticket.id).delete_all
        Ticketing::Ticket.where(id: @ticket.id).delete_all

        Orders::Order.where(id: order_id).update_all(status: "draft", paid_at: nil)
        Orders::OrderAdjustment.where(order_item_id: order_item_id).delete_all
        Orders::OrderItem.where(id: order_item_id).delete_all
        Orders::Order.where(id: order_id).delete_all

        Catalog::InventoryReservation.where(registration_id: registration_id).delete_all
        Catalog::VenueCapacityReservation.where(registration_id: registration_id).delete_all
        Core::DataRetentionHold.where(registration_id: registration_id).delete_all
        Ticketing::PurchaseLimitAllocation.where(registration_id: registration_id).delete_all
        Ticketing::PurchaseLimitOverride.where(registration_id: registration_id).delete_all
        Ticketing::RegistrationConsentWithdrawal.where(registration_id: registration_id).delete_all
        Ticketing::RegistrationConsent.where(registration_id: registration_id).delete_all
        Ticketing::RegistrationConsentRequirement.where(registration_id: registration_id).delete_all
        Ticketing::RegistrationFormSubmission.where(registration_id: registration_id).delete_all
        Ticketing::Registration.where(id: registration_id).delete_all

        Catalog::ProductPrice.where(event_product_id: product_id).delete_all
        Catalog::ProductDateAllocation.where(event_product_id: product_id).delete_all
        Catalog::ProductInventory.where(event_product_id: product_id).delete_all
        Catalog::ProductAccessZone.where(
          product_access_id: Catalog::ProductAccess.where(event_product_id: product_id).select(:id)
        ).delete_all
        Catalog::ProductAccess.where(event_product_id: product_id).delete_all
        Ticketing::AccessCode.where(ticket_type_id: ticket_type_id).delete_all
        Ticketing::Invitation.where(ticket_type_id: ticket_type_id).delete_all
        Events::ConsentDocumentProduct.where(ticket_type_id: ticket_type_id).delete_all
        Ticketing::PurchaseLimitAllocation.where(ticket_type_id: ticket_type_id).delete_all
        Ticketing::PurchaseLimitOverride.where(ticket_type_id: ticket_type_id).delete_all
        Ticketing::RegistrationForm.where(ticket_type_id: ticket_type_id).delete_all
        Ticketing::TicketType.where(id: ticket_type_id).delete_all
        Catalog::EventProduct.where(id: product_id).delete_all
        Events::EventDate.where(id: event_date_ids).delete_all
      end
    end

    test "concurrent opens leave one active suspension and one projection version" do
      barrier = Concurrent::CyclicBarrier.new(2)
      results = 2.times.map do |index|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            barrier.wait
            Ticketing::Suspensions::Open.call(
              ticket: @ticket,
              actor: @manager,
              reason_code: index.zero? ? "suspected_fraud" : "identity_review",
              review_deadline_at: 3.days.from_now,
              idempotency_key: "suspension-race-#{index}-#{SecureRandom.hex(8)}"
            )
          end
        end
      end.map(&:value)

      assert_equal 1, results.count(&:success?)
      assert_equal 1, results.count(&:failure?)
      assert_equal "suspension_already_active", results.find(&:failure?).error.code
      assert_equal 1, Ticketing::TicketSuspension.where(ticket_id: @ticket.id, status: "active").count
      assert_equal 1, @ticket.reload.revocation.revocation_version
    end
  end
end
