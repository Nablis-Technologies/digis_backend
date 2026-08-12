# frozen_string_literal: true

require "test_helper"

module Ticketing
  class PackageCredentialSchemaTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @event_date = @event.event_dates.create!(
        starts_at: 2.days.from_now,
        ends_at: 2.days.from_now + 2.hours,
        status: "scheduled"
      )
      @product = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Schema ticket #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "public",
          approval_mode: "automatic",
          date_selection: "fixed",
          admissions_per_unit: 2
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
      @product.product_accesses.create!(event_date: @event_date, type: "venue", usage_limit: 1)
      @registration = Ticketing::Registration.create!(
        event: @event,
        ticket_type: @product.ticket_type,
        user: @buyer,
        created_by: @buyer,
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity: 1,
        admissions_per_unit_snapshot: 2,
        party_size: 2,
        status: "confirmed",
        submitted_at: Time.current
      )
      @ticket = Ticketing::Ticket.create!(ticket_attributes)
      @first_slot = @ticket.admission_slots.create!(position: 1, assignment_status: "unassigned")
      @second_slot = @ticket.admission_slots.create!(position: 2, assignment_status: "unassigned")
    end

    test "business type columns do not trigger STI" do
      assert_predicate Ticketing::Credential.inheritance_column, :blank?
      assert_predicate Ticketing::AttendeeIndexEntry.inheritance_column, :blank?
    end

    test "requires one registration or order item and a same-event product" do
      invalid = Ticketing::Ticket.new(ticket_attributes.except(:registration_id))

      assert_not invalid.valid?
      assert invalid.errors.key?(:base)
    end

    test "creates exactly one admission slot per package position" do
      first = @first_slot
      second = @second_slot

      assert_equal [ 1, 2 ], @ticket.admission_slots.order(:position).pluck(:position)
      assert_equal 2, @ticket.admissions_per_unit_snapshot

      duplicate = second.dup
      duplicate.position = first.position
      assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
    end

    test "permits only one active generation per package" do
      first = @ticket.credential_generations.create!(
        version: 1,
        mode: "group",
        status: "active",
        activated_at: Time.current
      )
      assert_equal first, @ticket.credential_generations.active.first

      duplicate = @ticket.credential_generations.new(
        version: 2,
        mode: "delegated",
        status: "active",
        activated_at: Time.current
      )
      assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
    end

    test "permits one package credential per generation and one individual credential per slot" do
      generation = @ticket.credential_generations.create!(
        version: 1,
        mode: "group",
        status: "active",
        activated_at: Time.current
      )
      @ticket.update!(current_credential_generation: generation)
      first = generation.credentials.create!(credential_attributes(type: "package"))

      duplicate_package = first.dup
      duplicate_package.id = SecureRandom.uuid
      assert_raises(ActiveRecord::RecordNotUnique) { duplicate_package.save!(validate: false) }

      delegated = @ticket.credential_generations.create!(
        version: 2,
        mode: "delegated",
        status: "revoked",
        activated_at: Time.current,
        revoked_at: Time.current,
        revocation_reason: "mode_changed"
      )
      slot = @first_slot
      individual = delegated.credentials.create!(credential_attributes(
        type: "individual",
        admission_slot: slot,
        slot_positions: [ slot.position ],
        entry_limit: 1,
        status: "revoked",
        revoked_at: Time.current
      ))
      delegated.credentials.create!(credential_attributes(
        type: "individual",
        admission_slot: @second_slot,
        slot_positions: [ @second_slot.position ],
        entry_limit: 1,
        status: "revoked",
        revoked_at: Time.current
      ))
      duplicate_individual = individual.dup
      duplicate_individual.id = SecureRandom.uuid
      assert_raises(ActiveRecord::RecordNotUnique) { duplicate_individual.save!(validate: false) }
    end

    test "database enforces credential mode and entry-limit shape" do
      generation = @ticket.credential_generations.create!(
        version: 1,
        mode: "group",
        status: "active",
        activated_at: Time.current
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::Credential.insert_all!([ credential_attributes(
          credential_generation_id: generation.id,
          type: "package",
          admission_slot_id: SecureRandom.uuid,
          slot_positions: [ 1, 1 ],
          entry_limit: 1
        ).merge(id: SecureRandom.uuid) ])
      end
    end

    test "database bounds admission slots to the package snapshot" do
      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::AdmissionSlot.insert_all!([ {
          id: SecureRandom.uuid,
          ticket_id: @ticket.id,
          position: 3,
          assignment_status: "unassigned",
          created_at: Time.current,
          updated_at: Time.current
        } ])
      end
    end

    test "database requires usable credentials to belong to the current generation" do
      generation = @ticket.credential_generations.create!(
        version: 1,
        mode: "group",
        status: "active",
        activated_at: Time.current
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::Credential.insert_all!([ credential_attributes(
          credential_generation_id: generation.id,
          type: "package"
        ).merge(id: SecureRandom.uuid) ])
      end
    end

    test "deferred trigger requires a complete group credential set" do
      generation = @ticket.credential_generations.create!(
        version: 1,
        mode: "group",
        status: "active",
        activated_at: Time.current
      )
      @ticket.update!(current_credential_generation: generation)

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::Credential.transaction(requires_new: true) do
          generation.credentials.create!(credential_attributes(
            type: "package",
            slot_positions: [ 1 ],
            entry_limit: 1
          ))
          Ticketing::ApplicationRecord.connection.execute(
            "SET CONSTRAINTS trg_ticketing_credential_generation_cardinality IMMEDIATE"
          )
        end
      end
    end

    test "database enforces acquisition and package-count checks" do
      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::Ticket.insert_all!([ ticket_attributes.merge(
          id: SecureRandom.uuid,
          current_acquisition_type: "primary_purchase",
          current_acquisition_order_item_id: nil
        ) ])
      end

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::Ticket.insert_all!([ ticket_attributes.merge(
          id: SecureRandom.uuid,
          completed_resale_count: -1
        ) ])
      end
    end

    test "credential claims are one-to-one and token digests are unique" do
      generation = @ticket.credential_generations.create!(
        version: 1,
        mode: "delegated",
        status: "active",
        activated_at: Time.current
      )
      @ticket.update!(current_credential_generation: generation, credential_mode: "delegated")
      slot = @first_slot
      slot.update!(assignment_status: "pending_claim")
      credential = generation.credentials.create!(credential_attributes(
        type: "individual",
        admission_slot: slot,
        slot_positions: [ 1 ],
        entry_limit: 1,
        status: "pending_claim",
        qr_token: nil,
        lookup_code: nil,
        issued_at: nil
      ))
      claim = credential.create_credential_claim!(claim_attributes)

      duplicate_credential_claim = claim.dup
      duplicate_credential_claim.id = SecureRandom.uuid
      assert_raises(ActiveRecord::RecordNotUnique) { duplicate_credential_claim.save!(validate: false) }

      other_credential = generation.credentials.create!(credential_attributes(
        type: "individual",
        admission_slot: @second_slot,
        slot_positions: [ 2 ],
        entry_limit: 1,
        status: "pending_claim",
        qr_token: nil,
        lookup_code: nil,
        issued_at: nil
      ))
      assert_raises(ActiveRecord::RecordNotUnique) do
        other_credential.create_credential_claim!(claim_attributes(credential_id: other_credential.id))
      end
    end

    test "revocation and attendee index projections have stable identities" do
      generation = @ticket.credential_generations.create!(
        version: 1,
        mode: "group",
        status: "active",
        activated_at: Time.current
      )
      @ticket.update!(current_credential_generation: generation)
      generation.credentials.create!(credential_attributes(type: "package"))
      revocation = Ticketing::Revocation.create!(
        ticket: @ticket,
        event: @event,
        revoked_through_version: 1,
        is_dead: false,
        is_suspended: true,
        revocation_version: 1
      )
      assert_equal revocation, @ticket.reload.revocation

      entry = Ticketing::AttendeeIndexEntry.create!(index_attributes)
      duplicate = entry.dup
      duplicate.id = SecureRandom.uuid
      assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
    end

    test "earlier nullable references use deferred admission-slot and ticket foreign keys" do
      checks = {
        "ticketing_registration_answers" => "admission_slot_id",
        "ticketing_registration_consent_requirements" => "admission_slot_id",
        "ticketing_purchase_limit_allocations" => "ticket_id"
      }

      checks.each do |table, column|
        foreign_key = Ticketing::ApplicationRecord.connection.foreign_keys(table).find do |candidate|
          candidate.options[:column].to_s == column
        end
        assert foreign_key, "expected #{table}.#{column} foreign key"
        assert_equal :deferred, foreign_key.options[:deferrable]
      end
    end

    private

    def ticket_attributes
      {
        id: SecureRandom.uuid,
        event_id: @event.id,
        event_product_id: @product.id,
        registration_id: @registration.id,
        unit_number: 1,
        admissions_per_unit_snapshot: 2,
        owner_user_id: @buyer.id,
        current_acquisition_type: "free_registration",
        current_acquisition_product_value_minor: 0,
        current_acquisition_currency: "ETB",
        completed_resale_count: 0,
        credential_mode: "group",
        credential_version: 1,
        status: "active",
        issued_at: Time.current,
        lock_version: 0,
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    def credential_attributes(overrides = {})
      {
        id: SecureRandom.uuid,
        ticket_id: @ticket.id,
        credential_generation_id: overrides.fetch(:credential_generation_id) { @ticket.credential_generations.first&.id },
        admission_slot_id: nil,
        event_id: @event.id,
        type: "package",
        status: "active",
        slot_positions: [ 1, 2 ],
        entry_limit: 2,
        qr_token: "signed-token",
        lookup_code: "PNR#{SecureRandom.hex(3)}".upcase[0, 8],
        issued_at: Time.current,
        created_at: Time.current,
        updated_at: Time.current
      }.merge(overrides)
    end

    def claim_attributes(overrides = {})
      {
        credential_id: overrides.fetch(:credential_id) { @ticket.credentials.last.id },
        contact_digest: SecureRandom.hex(32),
        token_digest: "a" * 64,
        status: "pending",
        expires_at: 1.hour.from_now,
        created_at: Time.current,
        updated_at: Time.current
      }.merge(overrides)
    end

    def index_attributes
      {
        id: SecureRandom.uuid,
        event_id: @event.id,
        ticket_id: @ticket.id,
        credential_id: @ticket.credentials.last.id,
        lookup_code: "INDEX01",
        slot_positions: [ 1, 2 ],
        credential_mode: "group",
        generation_version: 1,
        entry_limit: 2,
        ticket_type: "ticket",
        ticket_type_label: "Schema ticket",
        product_access_ids: [ @product.product_accesses.first.id ],
        index_version: 1,
        removed: false,
        created_at: Time.current,
        updated_at: Time.current
      }
    end
  end
end
