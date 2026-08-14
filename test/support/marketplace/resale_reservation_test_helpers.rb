# frozen_string_literal: true

require_relative "commercial_resale_test_helpers"
require_relative "../ticketing/package_workflow_test_helpers"

module Marketplace
  module ResaleReservationTestHelpers
    include CommercialResaleTestHelpers
    include Ticketing::PackageWorkflowTestHelpers

    def setup_resale_reservation_context
      setup_package_workflow(admissions_per_unit: 3)
      setup_resale_commercial_terms
      configure_resale_policy
      @listing = activate_listing
      @buyer = core_users(:core_admin)
      @second_buyer = core_users(:support)
      @seller_allocation = Ticketing::PurchaseLimitAllocation.create!(
        ticket_type: @product.ticket_type,
        user: @owner,
        registration: @registration,
        unit_number: 1,
        ticket_id: @ticket.id,
        status: "committed",
        committed_at: Time.current,
        idempotency_key: "seller-historical-#{@ticket.id}"
      )
    end

    private

    def configure_resale_policy
      @ticket_type = @product.ticket_type
      @ticket_type.update!(
        resale_enabled: true,
        resale_cutoff_seconds_before_start: 3_600,
        resale_price_cap_type: "fixed",
        resale_fixed_cap_minor: 3_000,
        resale_fixed_cap_currency: "ETB",
        max_packages_per_user: 1,
        max_completed_resales: 2
      )
    end

    def setup_resale_commercial_terms
      @organization = @event.organization
      @quoted_at = Time.current.change(usec: 0)
      @commercial_version = create_active_commercial_version(
        code: "resale_reservation_#{SecureRandom.hex(6)}",
        schedule_type: "platform_default"
      ) do |version|
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100)
        create_fixed_component(version, component_type: "processing_cost_recovery", fixed_amount_minor: 50)
        create_fixed_component(
          version,
          component_type: "resale_platform_fee",
          fixed_amount_minor: 300,
          sale_context: "resale",
          sales_channel: "resale",
          charged_to: "organizer",
          funded_by: "organizer"
        )
      end
      # Use an event-scoped assignment so the reservation fixture has one
      # authoritative Commercial source even when the test database is not
      # populated by application seeds.
      @commercial_assignment = create_active_commercial_assignment(@commercial_version, event: @event)
    end

    def activate_listing
      result = ActivateListing.call(
        ticket: @ticket,
        actor: @owner,
        asking_amount_minor: 2_500,
        idempotency_key: "activate-reservation-#{SecureRandom.hex(8)}"
      )
      assert_predicate result, :success?, result.error&.message
      result.value
    end

    def cleanup_resale_reservation_fixture
      return unless @product&.persisted?

      buyer_ids = [ @buyer, @second_buyer ].compact.map(&:id)
      registration_ids = Ticketing::Registration.where(
        ticket_type_id: @product.ticket_type.id,
        user_id: buyer_ids
      ).pluck(:id)
      order_ids = Orders::Order.where(
        event_id: @event.id,
        buyer_user_id: buyer_ids,
        sales_channel: "resale"
      ).pluck(:id)
      order_item_ids = Orders::OrderItem.where(order_id: order_ids).pluck(:id)

      # Reopen the fixture orders before deleting immutable adjustment and item
      # snapshots. Production orders never use this path; it only makes the
      # non-transactional concurrency test teardown respect the same database
      # immutability trigger as the application.
      Orders::Order.where(id: order_ids).update_all(status: "draft", closed_reason: nil, paid_at: nil)
      Ticketing::PurchaseLimitAllocation.where(
        ticket_type_id: @product.ticket_type.id,
        user_id: [ @owner.id, *buyer_ids ]
      ).delete_all
      ResaleListing.where(ticket_id: @ticket.id).delete_all
      Orders::OrderAdjustment.where(order_id: order_ids).delete_all
      Orders::OrderItem.where(id: order_item_ids).delete_all
      Orders::Order.where(id: order_ids).delete_all
      Ticketing::RegistrationConsent.where(registration_id: registration_ids).delete_all
      Ticketing::RegistrationConsentRequirement.where(registration_id: registration_ids).delete_all
      Ticketing::RegistrationFormSubmission.where(registration_id: registration_ids).delete_all
      Ticketing::Registration.where(id: registration_ids).delete_all
      Core::OutboxEvent.where(aggregate_id: [ @ticket.id, @listing&.id ].compact).delete_all

      cleanup_commercial_reservation_fixture
      cleanup_package_fixture_graph
    end

    def cleanup_commercial_reservation_fixture
      version_id = @commercial_version&.id
      return unless version_id

      component_ids = Commercial::FeeComponent.where(fee_schedule_version_id: version_id).pluck(:id)
      Commercial::FeeScheduleVersion.where(id: version_id).update_all(
        status: "draft", activated_by_id: nil, activated_at: nil
      )
      Commercial::Assignment.where(fee_schedule_version_id: version_id).delete_all
      Commercial::FeeAmount.where(fee_component_id: component_ids).delete_all
      Commercial::FeeTier.where(fee_component_id: component_ids).delete_all
      Commercial::FeeComponent.where(id: component_ids).delete_all
      Commercial::FeeScheduleVersion.where(id: version_id).delete_all
      Commercial::FeeSchedule.where(id: @commercial_version.fee_schedule_id).delete_all
    end

    def cleanup_package_fixture_graph
      ticket_id = @ticket.id
      product_id = @product.id
      ticket_type_id = @product.ticket_type.id
      registration_id = @registration.id
      event_date_ids = @product.product_accesses.pluck(:event_date_id)
      product_access_ids = @product.product_accesses.pluck(:id)
      order_item_ids = [ @ticket.current_acquisition_order_item_id ].compact
      order_ids = Orders::OrderItem.where(id: order_item_ids).pluck(:order_id)
      generation_ids = Ticketing::CredentialGeneration.where(ticket_id: ticket_id).pluck(:id)
      credential_ids = Ticketing::Credential.where(ticket_id: ticket_id).pluck(:id)
      admission_slot_ids = Ticketing::AdmissionSlot.where(ticket_id: ticket_id).pluck(:id)

      Ticketing::AdmissionUse.where(admission_slot_id: admission_slot_ids).delete_all
      Ticketing::CheckinLog.where(ticket_id: ticket_id).delete_all
      Ticketing::CredentialClaim.where(credential_id: credential_ids).delete_all
      Ticketing::CredentialRevocation.where(credential_id: credential_ids).delete_all
      Ticketing::AttendeeIndexEntry.where(credential_id: credential_ids).delete_all
      Ticketing::Credential.transaction do
        Ticketing::Credential.where(id: credential_ids).delete_all
        Ticketing::Ticket.where(id: ticket_id).update_all(current_credential_generation_id: nil)
        Ticketing::CredentialGeneration.where(id: generation_ids).delete_all
      end
      Ticketing::AdmissionSlot.where(id: admission_slot_ids).delete_all
      Ticketing::TicketSuspension.where(ticket_id: ticket_id).delete_all
      Ticketing::Revocation.where(ticket_id: ticket_id).delete_all
      Ticketing::Ticket.where(id: ticket_id).delete_all

      Orders::Order.where(id: order_ids).update_all(status: "draft", closed_reason: nil, paid_at: nil)
      Orders::OrderAdjustment.where(order_item_id: order_item_ids).delete_all
      Orders::OrderItem.where(id: order_item_ids).delete_all
      Orders::Order.where(id: order_ids).delete_all
      Ticketing::PurchaseLimitAllocation.where(registration_id: registration_id).delete_all
      Ticketing::RegistrationConsent.where(registration_id: registration_id).delete_all
      Ticketing::RegistrationConsentRequirement.where(registration_id: registration_id).delete_all
      Ticketing::RegistrationFormSubmission.where(registration_id: registration_id).delete_all
      Ticketing::Registration.where(id: registration_id).delete_all

      Catalog::InventoryReservation.where(product_inventory_id: Catalog::ProductInventory.where(event_product_id: product_id).select(:id)).delete_all
      Catalog::VenueCapacityReservation.where(event_product_id: product_id).delete_all
      Catalog::ProductAccessZone.where(product_access_id: product_access_ids).delete_all
      Catalog::ProductAccess.where(id: product_access_ids).delete_all
      Catalog::ProductDateAllocation.where(event_product_id: product_id).delete_all
      Catalog::ProductInventory.where(event_product_id: product_id).delete_all
      Catalog::ProductPrice.where(event_product_id: product_id).delete_all
      Ticketing::RegistrationForm.where(ticket_type_id: ticket_type_id).delete_all
      Ticketing::PurchaseLimitOverride.where(ticket_type_id: ticket_type_id).delete_all
      Ticketing::TicketType.where(id: ticket_type_id).delete_all
      Catalog::EventProduct.where(id: product_id).delete_all
      Events::EventDate.where(id: event_date_ids).delete_all
    end
  end
end
