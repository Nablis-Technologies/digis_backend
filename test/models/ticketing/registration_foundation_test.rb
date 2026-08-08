# frozen_string_literal: true

require "test_helper"

module Ticketing
  class RegistrationFoundationTest < ActiveSupport::TestCase
    test "requires a positive party snapshot matching the package equation" do
      registration = Registration.new(
        event: events_events(:ready_listing),
        ticket_type: ticket_type_for(events_events(:ready_listing), admissions_per_unit: 2),
        user: core_users(:attendee),
        created_by: core_users(:attendee),
        source: "self_service",
        identity_digest: "a" * 64,
        package_quantity: 1,
        admissions_per_unit_snapshot: 2,
        party_size: 1,
        status: "pending_payment",
        submitted_at: Time.current
      )

      assert_not registration.valid?
      assert registration.errors.key?(:party_size)
    end

    test "requires a reason and idempotency key for complimentary registrations" do
      registration = Registration.new(
        event: events_events(:ready_listing),
        ticket_type: ticket_type_for(events_events(:ready_listing)),
        user: core_users(:attendee),
        created_by: core_users(:super_admin),
        source: "organizer_complimentary",
        identity_digest: "a" * 64,
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "confirmed",
        submitted_at: Time.current
      )

      assert_not registration.valid?
      assert registration.errors.key?(:complimentary_reason)
      assert registration.errors.key?(:issuance_idempotency_key)
    end

    test "normalizes form names and rejects duplicate event-wide names" do
      event = events_events(:ready_listing)
      first = RegistrationForm.create!(event:, name: "Attendee details", active: true)
      duplicate = RegistrationForm.new(event:, name: "  attendee   details ", active: true)

      assert_equal "attendee details", duplicate.tap(&:valid?).name
      assert first.persisted?
      assert_not duplicate.valid?
      assert duplicate.errors.key?(:name)
    end

    test "rejects a choose-one date that is not covered by product access" do
      event = events_events(:ready_listing)
      actor = core_users(:super_admin)
      product = Catalog::Products::CreateDraft.call(
        event:,
        actor:,
        product_attributes: { name: "Choose one ticket", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "choose_one",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
      event_date = event.event_dates.create!(
        starts_at: 1.day.from_now,
        ends_at: 1.day.from_now + 1.hour,
        status: "scheduled"
      )
      registration = Registration.new(
        event:,
        ticket_type: product.ticket_type,
        user: core_users(:attendee),
        created_by: actor,
        source: "self_service",
        identity_digest: "e" * 64,
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        selected_event_date: event_date,
        status: "pending_payment",
        submitted_at: Time.current
      )

      assert_not registration.valid?
      assert registration.errors.key?(:selected_event_date)
    end

    test "database rejects cross-event registration form and submission links" do
      event = events_events(:ready_listing)
      other_event = events_events(:draft_concert)
      actor = core_users(:super_admin)
      other_product = Catalog::Products::CreateDraft.call(
        event: other_event,
        actor:,
        product_attributes: { name: "Other event ticket", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value

      assert_raises(ActiveRecord::StatementInvalid) do
        Registration.transaction(requires_new: true) do
          Registration.insert_all!([
            {
              id: SecureRandom.uuid,
              event_id: event.id,
              ticket_type_id: other_product.ticket_type.id,
              user_id: core_users(:attendee).id,
              source: "self_service",
              created_by_id: actor.id,
              identity_digest: "8" * 64,
              package_quantity: 1,
              admissions_per_unit_snapshot: 1,
              party_size: 1,
              status: "pending_payment",
              submitted_at: Time.current,
              lock_version: 0,
              created_at: Time.current,
              updated_at: Time.current
            }
          ])
        end
      end

      assert_raises(ActiveRecord::StatementInvalid) do
        RegistrationForm.transaction(requires_new: true) do
          RegistrationForm.insert_all!([
            {
              id: SecureRandom.uuid,
              event_id: event.id,
              ticket_type_id: other_product.ticket_type.id,
              name: "Cross-event form",
              active: true,
              created_at: Time.current,
              updated_at: Time.current
            }
          ])
        end
      end

      registration_product = Catalog::Products::CreateDraft.call(
        event:,
        actor:,
        product_attributes: { name: "Registration event ticket", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
      registration = Registration.create!(
        event:,
        ticket_type: registration_product.ticket_type,
        user: core_users(:attendee),
        created_by: actor,
        source: "self_service",
        identity_digest: "9" * 64,
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "pending_payment",
        submitted_at: Time.current
      )
      form = RegistrationForm.create!(event: other_event, name: "Other event details", active: true)
      version = form.versions.create!(
        version: 1,
        status: "published",
        published_by: actor,
        published_at: Time.current
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        RegistrationFormSubmission.transaction(requires_new: true) do
          RegistrationFormSubmission.insert_all!([
            {
              id: SecureRandom.uuid,
              registration_id: registration.id,
              registration_form_version_id: version.id,
              submitted_by_user_id: core_users(:attendee).id,
              submitted_at: Time.current,
              created_at: Time.current,
              updated_at: Time.current
            }
          ])
        end
      end
    end

    test "published forms cannot change their ticket scope" do
      event = events_events(:ready_listing)
      actor = core_users(:super_admin)
      product = Catalog::Products::CreateDraft.call(
        event:,
        actor:,
        product_attributes: { name: "Scoped ticket", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
      form = RegistrationForm.create!(event:, name: "Published scope", active: true)
      version = form.versions.create!(version: 1, status: "draft")
      version.update!(status: "published", published_by: actor, published_at: Time.current)

      form.ticket_type = product.ticket_type

      assert_not form.valid?
      assert form.errors.key?(:ticket_type_id)
      assert_raises(ActiveRecord::StatementInvalid) do
        RegistrationForm.where(id: form.id).update_all(ticket_type_id: product.ticket_type.id)
      end
    end

    test "retiring a published version does not violate version monotonicity" do
      form = RegistrationForm.create!(event: events_events(:ready_listing), name: "Retirement details", active: true)
      published = form.versions.create!(
        version: 1,
        status: "published",
        published_by: core_users(:super_admin),
        published_at: Time.current
      )
      form.versions.create!(version: 2, status: "draft")

      published.status = "retired"

      assert_predicate published, :valid?
    end

    test "registration scope cannot change after form submissions exist" do
      event = events_events(:ready_listing)
      actor = core_users(:super_admin)
      first_product = Catalog::Products::CreateDraft.call(
        event:,
        actor:,
        product_attributes: { name: "First registration ticket", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
      second_product = Catalog::Products::CreateDraft.call(
        event:,
        actor:,
        product_attributes: { name: "Second registration ticket", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
      registration = Registration.create!(
        event:,
        ticket_type: first_product.ticket_type,
        user: core_users(:attendee),
        created_by: actor,
        source: "self_service",
        identity_digest: "7" * 64,
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "pending_payment",
        submitted_at: Time.current
      )
      form = RegistrationForm.create!(event:, name: "Scope details", active: true)
      version = form.versions.create!(version: 1, status: "draft")
      version.update!(status: "published", published_by: actor, published_at: Time.current)
      registration.form_submissions.create!(
        registration_form_version: version,
        submitted_by_user: core_users(:attendee),
        submitted_at: Time.current
      )

      registration.ticket_type = second_product.ticket_type

      assert_not registration.valid?
      assert registration.errors.key?(:ticket_type_id)
      assert_raises(ActiveRecord::StatementInvalid) do
        Registration.transaction(requires_new: true) do
          Registration.where(id: registration.id).update_all(ticket_type_id: second_product.ticket_type.id)
        end
      end
    end

    test "form submissions and registration snapshots are immutable" do
      event = events_events(:ready_listing)
      actor = core_users(:super_admin)
      product = Catalog::Products::CreateDraft.call(
        event:,
        actor:,
        product_attributes: { name: "Snapshot ticket", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
      registration = Registration.create!(
        event:,
        ticket_type: product.ticket_type,
        user: core_users(:attendee),
        created_by: actor,
        source: "self_service",
        identity_digest: "6" * 64,
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "pending_payment",
        submitted_at: Time.current
      )
      form = RegistrationForm.create!(event:, name: "Snapshot details", active: true)
      version = form.versions.create!(
        version: 1,
        status: "published",
        published_by: actor,
        published_at: Time.current
      )
      submission = registration.form_submissions.create!(
        registration_form_version: version,
        submitted_by_user: core_users(:support),
        submitted_at: Time.current
      )
      event_date = event.event_dates.create!(
        starts_at: 1.day.from_now,
        ends_at: 1.day.from_now + 1.hour,
        status: "scheduled"
      )
      other_event = events_events(:draft_concert)

      submission.submitted_at = 1.minute.ago
      assert_raises(ActiveRecord::ReadOnlyRecord) { submission.save! }
      assert_raises(ActiveRecord::StatementInvalid) do
        RegistrationFormSubmission.transaction(requires_new: true) do
          RegistrationFormSubmission.where(id: submission.id).update_all(submitted_at: 1.minute.ago)
        end
      end
      assert_raises(ActiveRecord::ReadOnlyRecord) { submission.destroy! }
      assert_raises(ActiveRecord::StatementInvalid) do
        RegistrationFormSubmission.transaction(requires_new: true) do
          RegistrationFormSubmission.where(id: submission.id).delete_all
        end
      end

      registration.package_quantity = 2
      assert_not registration.valid?
      assert registration.errors.key?(:package_quantity)

      registration.reload
      registration.admissions_per_unit_snapshot = 2
      assert_not registration.valid?
      assert registration.errors.key?(:admissions_per_unit_snapshot)

      registration.reload
      registration.party_size = 2
      assert_not registration.valid?
      assert registration.errors.key?(:party_size)

      registration.reload
      registration.selected_event_date_id = event_date.id
      assert_not registration.valid?
      assert registration.errors.key?(:selected_event_date_id)

      registration.reload
      registration.event_id = other_event.id
      assert_not registration.valid?
      assert registration.errors.key?(:event_id)

      assert_raises(ActiveRecord::StatementInvalid) do
        Registration.transaction(requires_new: true) do
          Registration.where(id: registration.id).update_all(event_id: other_event.id)
        end
      end

      assert_raises(ActiveRecord::StatementInvalid) do
        Registration.transaction(requires_new: true) do
          Registration.where(id: registration.id).update_all(package_quantity: 2, party_size: 2)
        end
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        Registration.transaction(requires_new: true) do
          Registration.where(id: registration.id).update_all(admissions_per_unit_snapshot: 2, party_size: 2)
        end
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        Registration.transaction(requires_new: true) do
          Registration.where(id: registration.id).update_all(selected_event_date_id: event_date.id)
        end
      end
    end

    test "published form versions cannot change content" do
      form = RegistrationForm.create!(event: events_events(:ready_listing), name: "Details", active: true)
      version = form.versions.create!(
        version: 1,
        status: "draft"
      )
      question = version.questions.create!(
        key: "name",
        type: "short_text",
        response_scope: "registration",
        sensitivity: "standard",
        label: "Name",
        position: 0,
        options: [],
        validation_rules: {}
      )
      version.update!(
        status: "published",
        published_by: core_users(:super_admin),
        published_at: Time.current
      )

      version.version = 2

      assert_not version.valid?
      assert version.errors.key?(:base)

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationFormVersion.transaction(requires_new: true) do
          Ticketing::RegistrationFormVersion.where(id: version.id).update_all(version: 2)
        end
      end

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationQuestion.transaction(requires_new: true) do
          Ticketing::RegistrationQuestion.where(id: question.id).update_all(label: "Changed")
        end
      end
    end

    test "rejects executable and regular-expression validation rules" do
      question = RegistrationQuestion.new(
        type: "short_text",
        response_scope: "registration",
        sensitivity: "standard",
        key: "name",
        label: "Name",
        position: 0,
        options: [],
        validation_rules: { "pattern" => ".*" }
      )

      assert_not question.valid?
      assert question.errors.key?(:validation_rules)
    end

    test "rejects duplicate allowed option keys" do
      question = RegistrationQuestion.new(
        type: "single_choice",
        response_scope: "registration",
        sensitivity: "standard",
        key: "meal",
        label: "Meal",
        position: 0,
        options: [ { "key" => "standard", "label" => "Standard" } ],
        validation_rules: { "allowed_option_keys" => [ "standard", "standard" ] }
      )

      assert_not question.valid?
      assert question.errors.key?(:validation_rules)
    end

    test "requires slot coordinates only for admission-slot answers" do
      answer = RegistrationAnswer.new(
        response_scope_snapshot: "admission_slot",
        question_type_snapshot: "short_text",
        question_key_snapshot: "name",
        question_label_snapshot: "Name",
        package_unit_number: nil,
        admission_position: 1,
        answer: "Ada",
        answered_at: Time.current,
        retain_until: 1.day.from_now
      )

      assert_not answer.valid?
      assert answer.errors.key?(:package_unit_number)
    end

    test "registration queue is indexed by ticket type, date, status, and wait time" do
      index = Ticketing::Registration.connection.indexes("ticketing_registrations")
        .find { |candidate| candidate.name == "idx_ticketing_registrations_queue" }

      assert index, "expected a queue index for waitlist processing"
      assert_equal %w[ticket_type_id selected_event_date_id status waitlisted_at id], index.columns
    end

    test "database protects submitted source and state timestamps" do
      event = events_events(:ready_listing)
      actor = core_users(:super_admin)
      product = Catalog::Products::CreateDraft.call(
        event:,
        actor:,
        product_attributes: { name: "Immutable registration", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
      registration = Registration.create!(
        event:,
        ticket_type: product.ticket_type,
        user: core_users(:attendee),
        created_by: actor,
        source: "self_service",
        identity_digest: "f" * 64,
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "pending_payment",
        submitted_at: Time.current
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Registration.transaction(requires_new: true) do
          Registration.where(id: registration.id).update_all(source: "walk_up")
        end
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        Registration.transaction(requires_new: true) do
          Registration.where(id: registration.id).update_all(waitlisted_at: Time.current)
        end
      end
    end

    test "requires a manager reason for answer revisions" do
      revision = RegistrationAnswerRevision.new(
        source: "manager_correction",
        revision_number: 1,
        answer: "Corrected",
        revised_by: core_users(:super_admin),
        idempotency_key_digest: "1" * 64,
        request_digest: "a" * 64,
        revised_at: Time.current
      )

      assert_not revision.valid?
      assert revision.errors.key?(:reason_code)
    end

    private

    def ticket_type_for(event, admissions_per_unit: 1)
      product = Catalog::EventProduct.new(event:, name: "Ticket", type: "ticket")
      Ticketing::TicketType.new(event_product: product, admissions_per_unit: admissions_per_unit)
    end
  end
end
