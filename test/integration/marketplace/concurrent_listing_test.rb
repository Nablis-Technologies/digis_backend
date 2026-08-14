# frozen_string_literal: true

require "test_helper"

module Marketplace
  class ConcurrentListingTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include CommercialResaleTestHelpers
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 3)
      setup_commercial_terms
      configure_resale_policy
    end

    teardown do
      cleanup_package_fixture
      component_ids = Commercial::FeeComponent.where(fee_schedule_version_id: @commercial_version.id).pluck(:id)
      connection = Commercial::ApplicationRecord.connection
      triggers = {
        "commercial_fee_amounts" => "trg_commercial_fee_amount_immutable",
        "commercial_fee_components" => "trg_commercial_fee_component_immutable",
        "commercial_fee_schedule_versions" => "trg_commercial_fee_schedule_version_immutable"
      }
      triggers.each { |table, trigger| connection.execute("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}") }
      begin
        Commercial::FeeAmount.where(fee_component_id: component_ids).delete_all
        Commercial::FeeTier.where(fee_component_id: component_ids).delete_all
        Commercial::FeeComponent.where(id: component_ids).delete_all
        Commercial::FeeScheduleVersion.where(id: @commercial_version.id).delete_all
        Commercial::FeeSchedule.where(id: @commercial_version.fee_schedule_id).delete_all
      ensure
        triggers.each { |table, trigger| connection.execute("ALTER TABLE #{table} ENABLE TRIGGER #{trigger}") }
      end
    end

    test "concurrent activation creates only one open listing" do
      ready = Queue.new
      start = Queue.new
      threads = 2.times.map do |index|
        Thread.new do
          ready << true
          start.pop
          Ticketing::ApplicationRecord.connection_pool.with_connection do
            ActivateListing.call(
              ticket: Ticketing::Ticket.find(@ticket.id),
              actor: Core::User.find(@owner.id),
              asking_amount_minor: 2_500,
              idempotency_key: "concurrent-listing-#{index}-#{SecureRandom.hex(4)}"
            )
          end
        end
      end

      2.times { ready.pop }
      2.times { start << true }
      results = threads.map(&:value)

      assert_equal 1, results.count(&:success?), results.map { |result| [ result.success?, result.error&.code ] }.inspect
      assert_equal 1, results.count(&:failure?), results.map { |result| [ result.success?, result.error&.code ] }.inspect
      assert_equal "listing_already_open", results.find(&:failure?).error.code
      assert_equal 1, ResaleListing.where(ticket_id: @ticket.id, status: "active").count
    ensure
      threads&.each(&:join)
    end

    private

    # This spec deliberately disables transactional tests so two database
    # connections can race the activation transaction. Clean only the package
    # graph created by the helper before Rails reloads shared fixtures; leaving
    # the issued ticket behind would make the next fixture load reference a
    # product that this teardown has already removed.
    def cleanup_package_fixture
      ticket_id = @ticket.id
      product_id = @product.id
      ticket_type_id = @product.ticket_type.id
      registration_id = @registration.id
      event_date_ids = @product.product_accesses.pluck(:event_date_id)
      product_access_ids = @product.product_accesses.pluck(:id)
      product_inventory_ids = Catalog::ProductInventory.where(event_product_id: product_id).pluck(:id)
      order_item_ids = @ticket.current_acquisition_order_item_id.present? ? [ @ticket.current_acquisition_order_item_id ] : []
      order_ids = Orders::OrderItem.where(id: order_item_ids).pluck(:order_id)
      generation_ids = Ticketing::CredentialGeneration.where(ticket_id: ticket_id).pluck(:id)
      credential_ids = Ticketing::Credential.where(ticket_id: ticket_id).pluck(:id)
      admission_slot_ids = Ticketing::AdmissionSlot.where(ticket_id: ticket_id).pluck(:id)
      checkin_ids = Ticketing::CheckinLog.where(ticket_id: ticket_id).pluck(:id)

      ResaleListing.where(ticket_id: ticket_id).delete_all
      Marketplace::ResaleSale.where(ticket_id: ticket_id).delete_all
      Core::OutboxEvent.where(aggregate_id: ticket_id.to_s).delete_all

      Ticketing::AdmissionUseReversal.where(admission_use_id: Ticketing::AdmissionUse.where(admission_slot_id: admission_slot_ids).select(:id)).delete_all
      Ticketing::AdmissionUse.where(admission_slot_id: admission_slot_ids).delete_all
      Ticketing::CheckinLog.where(id: checkin_ids).update_all(overrides_checkin_log_id: nil)
      Ticketing::CheckinLog.where(id: checkin_ids).delete_all
      Ticketing::CredentialClaim.where(credential_id: credential_ids).delete_all
      Ticketing::CredentialRevocation.where(credential_id: credential_ids).delete_all
      Ticketing::AttendeeIndexEntry.where(credential_id: credential_ids).delete_all
      credential_connection = Ticketing::ApplicationRecord.connection
      credential_connection.execute(
        "ALTER TABLE ticketing_credentials DISABLE TRIGGER trg_ticketing_credential_generation_cardinality"
      )
      begin
        Ticketing::Credential.where(id: credential_ids).delete_all
      ensure
        credential_connection.execute(
          "ALTER TABLE ticketing_credentials ENABLE TRIGGER trg_ticketing_credential_generation_cardinality"
        )
      end

      Ticketing::Ticket.where(id: ticket_id).update_all(
        current_credential_generation_id: nil,
        current_acquisition_type: "free_registration",
        current_acquisition_product_value_minor: 0,
        current_acquisition_order_item_id: nil,
        order_item_id: nil
      )
      Ticketing::CredentialGeneration.where(id: generation_ids).delete_all
      Ticketing::AdmissionSlot.where(id: admission_slot_ids).delete_all
      Ticketing::TicketTransfer.where(ticket_id: ticket_id).delete_all
      Ticketing::TicketSuspension.where(ticket_id: ticket_id).delete_all
      Ticketing::Revocation.where(ticket_id: ticket_id).delete_all
      Ticketing::PurchaseLimitAllocation.where(ticket_id: ticket_id).delete_all
      Ticketing::Ticket.where(id: ticket_id).delete_all

      Orders::RefundItem.where(order_item_id: order_item_ids).delete_all
      Orders::OrderAdjustment.where(order_item_id: order_item_ids).delete_all
      order_connection = Orders::ApplicationRecord.connection
      order_triggers = {
        "orders_order_items" => "trg_orders_order_item_immutable",
        "orders_orders" => "trg_orders_order_immutable"
      }
      order_triggers.each { |table, trigger| order_connection.execute("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}") }
      begin
        Orders::OrderItem.where(id: order_item_ids).delete_all
        Orders::Order.where(id: order_ids).delete_all
      ensure
        order_triggers.each { |table, trigger| order_connection.execute("ALTER TABLE #{table} ENABLE TRIGGER #{trigger}") }
      end

      Ticketing::PurchaseLimitAllocation.where(registration_id: registration_id).delete_all
      Ticketing::PurchaseLimitOverride.where(registration_id: registration_id).delete_all
      Catalog::InventoryReservation.where(registration_id: registration_id).delete_all
      Catalog::VenueCapacityReservation.where(registration_id: registration_id).delete_all
      Core::DataRetentionHold.where(registration_id: registration_id).delete_all
      Ticketing::RegistrationConsentWithdrawal.where(registration_id: registration_id).delete_all
      Ticketing::RegistrationConsent.where(registration_id: registration_id).delete_all
      Ticketing::RegistrationConsentRequirement.where(registration_id: registration_id).delete_all
      Ticketing::RegistrationFormSubmission.where(registration_id: registration_id).delete_all
      Ticketing::Registration.where(id: registration_id).delete_all

      Catalog::InventoryReservation.where(product_inventory_id: product_inventory_ids).delete_all
      Catalog::VenueCapacityReservation.where(event_product_id: product_id).delete_all
      Catalog::ProductAccessZone.where(product_access_id: product_access_ids).delete_all
      Catalog::ProductAccess.where(id: product_access_ids).delete_all
      Catalog::ProductDateAllocation.where(event_product_id: product_id).delete_all
      Catalog::ProductInventory.where(event_product_id: product_id).delete_all
      Catalog::ProductPrice.where(event_product_id: product_id).delete_all
      Ticketing::AccessCode.where(ticket_type_id: ticket_type_id).delete_all
      Ticketing::Invitation.where(ticket_type_id: ticket_type_id).delete_all
      Ticketing::RegistrationForm.where(ticket_type_id: ticket_type_id).delete_all
      Ticketing::PurchaseLimitOverride.where(ticket_type_id: ticket_type_id).delete_all
      Ticketing::TicketType.where(id: ticket_type_id).delete_all
      Catalog::EventProduct.where(id: product_id).delete_all
      Events::EventDate.where(id: event_date_ids).delete_all
    end

    def configure_resale_policy
      @ticket_type = @product.ticket_type
      @ticket_type.update!(
        resale_enabled: true,
        resale_cutoff_seconds_before_start: 3_600,
        resale_price_cap_type: "fixed",
        resale_fixed_cap_minor: 3_000,
        resale_fixed_cap_currency: "ETB",
        max_completed_resales: 2
      )
    end

    def setup_commercial_terms
      @organization = @event.organization
      @quoted_at = Time.current.change(usec: 0)
      @commercial_version = create_active_commercial_version(
        code: "resale_race_#{SecureRandom.hex(6)}",
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
    end
  end
end
