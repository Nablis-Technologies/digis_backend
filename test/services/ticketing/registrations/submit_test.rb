# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Registrations
    class SubmitTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:attendee)
        @ticket_type = create_ticket_type
        @form, @question = create_required_form
        @retention_policy = Core::DataRetentionPolicy.create!(
          category: "registration_free_text",
          version: 1,
          retention_days: 30,
          action: "erase_payload",
          status: "active",
          effective_at: 1.minute.ago,
          created_by: core_users(:super_admin)
        )
      end

      test "resolves equivalent phone formats to the authenticated canonical identity" do
        result = submit(phone: "+251 911 000 003")

        assert_predicate result, :success?
        registration = result.value.registration
        assert_equal @actor, registration.user
        assert_equal 64, registration.identity_digest.length
        assert_equal registration.identity_digest, submit(phone: "251911000003").value.registration.identity_digest
      end

      test "requires a verified authenticated actor for the submitted phone" do
        @actor.update_column(:verified_at, nil)

        result = submit

        assert_predicate result, :failure?
        assert_equal "phone_identity_unverified", result.error.code
        assert_equal 0, Registration.count
      end

      test "rejects a phone that does not belong to the authenticated actor" do
        result = submit(phone: "251911000004")

        assert_predicate result, :failure?
        assert_equal "phone_identity_mismatch", result.error.code
        assert_equal 0, Registration.count
      end

      test "snapshots selected date and package sizing" do
        @ticket_type.update!(date_selection: "choose_one", admissions_per_unit: 2)
        date = @event.event_dates.create!(
          starts_at: 1.day.from_now,
          ends_at: 1.day.from_now + 1.hour,
          status: "scheduled"
        )
        Catalog::ProductAccess.create!(event_product: @ticket_type.event_product, event_date: date, type: "venue")

        result = submit(package_quantity: 3, selected_event_date_id: date.id)

        assert_predicate result, :success?
        registration = result.value.registration
        assert_equal date, registration.selected_event_date
        assert_equal 3, registration.package_quantity
        assert_equal 2, registration.admissions_per_unit_snapshot
        assert_equal 6, registration.party_size
      end

      test "locks and reloads the ticket type before snapshotting package sizing" do
        stale_ticket_type = @ticket_type
        Ticketing::TicketType.where(id: @ticket_type.id).update_all(admissions_per_unit: 2)

        result = submit(ticket_type: stale_ticket_type, package_quantity: 3)

        assert_predicate result, :success?
        assert_equal 2, result.value.registration.admissions_per_unit_snapshot
        assert_equal 6, result.value.registration.party_size
      end

      test "authorizes the ticket audience before persisting a registration" do
        @ticket_type.update!(audience: "access_code")

        result = submit

        assert_predicate result, :failure?
        assert_match(/access code required/i, result.error.message)
        assert_equal 0, Registration.count
      end

      test "rolls back when an active form has no published version" do
        RegistrationForm.create!(event: @event, name: "Unpublished current form", active: true)

        result = submit

        assert_predicate result, :failure?
        assert_equal "missing_published_version", result.error.code
        assert_equal 0, Registration.count
        assert_equal 0, RegistrationFormSubmission.count
      end

      test "rolls back when a selected form version becomes stale before persistence" do
        version = @form.versions.published.first
        schema = Core::BaseService::Result.success([ version ])
        version.update!(status: "retired")

        original_call = Ticketing::Forms::ApplicableSchema.method(:call)
        Ticketing::Forms::ApplicableSchema.define_singleton_method(:call) { |*_args, **_kwargs| schema }
        begin
          result = submit

          assert_predicate result, :failure?
          assert_equal "stale_form_version", result.error.code
        ensure
          Ticketing::Forms::ApplicableSchema.define_singleton_method(:call, original_call)
        end

        assert_equal 0, Registration.count
        assert_equal 0, RegistrationFormSubmission.count
      end

      test "rolls back when current form validation fails" do
        result = submit(answers: [])

        assert_predicate result, :failure?
        assert_equal "required_answer", result.error.code
        assert_equal 0, Registration.count
        assert_equal 0, RegistrationFormSubmission.count
      end

      test "persists exactly the current form version and answer snapshots" do
        result = submit

        assert_predicate result, :success?
        registration = result.value.registration
        persisted_answer = registration.form_submissions.first.answers.first
        assert_equal @form.versions.published.first, registration.form_submissions.first.registration_form_version
        assert_equal @question.key, persisted_answer.question_key_snapshot
        assert_equal @retention_policy, persisted_answer.retention_policy
      end

      test "returns the existing active registration for a safe retry and rejects a conflicting replay" do
        assert_idempotent(-> { submit }, counter: -> { Registration.count })
        first = submit

        assert_predicate first, :success?

        conflicting = submit(package_quantity: 2)
        assert_predicate conflicting, :failure?
        assert_equal "active_registration_conflict", conflicting.error.code
        assert_equal 1, Registration.count
      end

      test "uses an event-scoped keyed digest for canonical-equivalent answers and audience proof" do
        identity = Core::PhoneIdentity::ResolveOrCreate.call(phone: @actor.phone, actor: @actor).value
        first = submission_command(
          answers: [ { question_key: "name", value: "Ada" } ],
          audience_proof: { access_code: "code-1", invitation_token: "token-1" }
        )
        equivalent = submission_command(
          answers: [ { value: "Ada", question_key: "name" } ],
          audience_proof: { "invitation_token" => "token-1", "access_code" => "code-1" }
        )
        expected_payload = {
          "admissions_per_unit" => 1,
          "answers" => [ { "question_key" => "name", "value" => "Ada" } ],
          "audience_proof" => { "access_code" => "code-1", "invitation_token" => "token-1" },
          "identity_digest" => identity.digest,
          "package_quantity" => 1,
          "selected_event_date_id" => nil,
          "ticket_type_id" => @ticket_type.id
        }
        expected = Core::KeyedDigest.digest(
          namespace: "ticketing-registration-request:#{@event.id}",
          value: ActiveSupport::JSON.encode(expected_payload)
        )

        assert_equal expected, first.send(:request_digest, identity, @ticket_type)
        assert_equal first.send(:request_digest, identity, @ticket_type), equivalent.send(:request_digest, identity, @ticket_type)
      end

      test "returns a deferred confirmation action for automatic free registrations" do
        create_price(amount_minor: 0)

        result = submit

        assert_predicate result, :success?
        assert_equal "pending_payment", result.value.registration.status
        assert_equal "requires_confirmation", result.value.type
      end

      test "persists the automatic next action when the product price later changes" do
        price = create_price(amount_minor: 0)
        first = submit

        assert_predicate first, :success?
        assert_equal "requires_confirmation", first.value.type

        price.update!(amount_minor: 1_000)
        replay = submit

        assert_predicate replay, :success?
        assert_equal "requires_confirmation", replay.value.type
      end

      test "returns an order action for automatic paid registrations" do
        create_price(amount_minor: 1_000)

        result = submit

        assert_predicate result, :success?
        assert_equal "pending_payment", result.value.registration.status
        assert_equal "requires_order", result.value.type
      end

      test "returns an approval action for manual registrations" do
        @ticket_type.update!(approval_mode: "manual")

        result = submit

        assert_predicate result, :success?
        assert_equal "pending_approval", result.value.registration.status
        assert_equal "awaiting_approval", result.value.type
      end

      private

      def submit(ticket_type: @ticket_type, actor: @actor, phone: @actor.phone, package_quantity: 1,
                 selected_event_date_id: nil, answers: default_answers, audience_proof: {})
        assert defined?(Ticketing::Registrations::Submit), "expected registration submission command"

        submission = Ticketing::RegistrationSubmission.new(
          package_quantity:,
          selected_event_date_id:,
          answers:
        )
        Ticketing::Registrations::Submit.call(ticket_type:, actor:, phone:, submission:, audience_proof:)
      end

      def submission_command(answers:, audience_proof:)
        Ticketing::Registrations::Submit.new(
          ticket_type: @ticket_type,
          actor: @actor,
          phone: @actor.phone,
          submission: Ticketing::RegistrationSubmission.new(
            package_quantity: 1,
            selected_event_date_id: nil,
            answers:
          ),
          audience_proof:
        )
      end

      def create_ticket_type
        Catalog::Products::CreateDraft.call(
          event: @event,
          actor: core_users(:super_admin),
          product_attributes: { name: "Registration ticket #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
          },
          inventory_configuration: { mode: "unlimited" }
        ).value.ticket_type
      end

      def create_required_form
        form = RegistrationForm.create!(event: @event, name: "Registration details #{SecureRandom.hex(4)}", active: true)
        version = form.versions.create!(version: 1, status: "draft")
        question = version.questions.create!(
          key: "name",
          type: "short_text",
          response_scope: "registration",
          sensitivity: "standard",
          label: "Name",
          required: true,
          position: 0,
          options: [],
          validation_rules: {}
        )
        version.update!(status: "published", published_by: core_users(:super_admin), published_at: Time.current)
        [ form, question ]
      end

      def create_price(amount_minor:)
        @ticket_type.event_product.prices.create!(
          type: "base",
          currency: "ETB",
          amount_minor:,
          active_from: 1.minute.ago
        )
      end

      def default_answers
        [ { question_key: @question.key, value: "Ada" } ]
      end
    end
  end

  module Registrations
    class SubmitConcurrencyTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:attendee)
        @ticket_type = create_ticket_type
        @form, @question = create_required_form
        @retention_policy = Core::DataRetentionPolicy.create!(
          category: "registration_free_text",
          version: 1,
          retention_days: 30,
          action: "erase_payload",
          status: "active",
          effective_at: 1.minute.ago,
          created_by: core_users(:super_admin)
        )
      end

      teardown do
        cleanup_concurrent_records
      end

      test "concurrent same-identity submissions return one registration and one form snapshot" do
        ready = Queue.new
        start = Queue.new
        results = 2.times.map do
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              local_ticket_type = Ticketing::TicketType.find(@ticket_type.id)
              ready << true
              start.pop
              Submit.call(
                ticket_type: local_ticket_type,
                actor: Core::User.find(@actor.id),
                phone: @actor.phone,
                submission: Ticketing::RegistrationSubmission.new(
                  package_quantity: 1,
                  selected_event_date_id: nil,
                  answers: [ { question_key: @question.key, value: "Ada" } ]
                ),
                audience_proof: {}
              )
            end
          end
        end

        2.times { ready.pop }
        2.times { start << true }
        results = results.map(&:value)

        assert results.all?(&:success?), results.filter_map { |result| result.error&.message }.join(", ")
        registration_ids = results.map { |result| result.value.registration.id }
        assert_equal 1, registration_ids.uniq.length
        assert_equal 1, Registration.where(ticket_type: @ticket_type).count
        assert_equal 1, RegistrationFormSubmission.where(registration_id: registration_ids.first).count
      end

      test "concurrent same-key submissions for different ticket types return a typed conflict" do
        @form.update!(active: false)
        @other_ticket_type = create_ticket_type
        install_registration_insert_delay
        ready = Queue.new
        start = Queue.new

        results = [ @ticket_type, @other_ticket_type ].map do |current_ticket_type|
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              ready << true
              start.pop
              Submit.call(
                ticket_type: Ticketing::TicketType.find(current_ticket_type.id),
                actor: Core::User.find(@actor.id),
                phone: @actor.phone,
                submission: Ticketing::RegistrationSubmission.new(
                  package_quantity: 1,
                  selected_event_date_id: nil,
                  answers: []
                ),
                audience_proof: {},
                idempotency_key: "cross-ticket-idempotency-race"
              )
            rescue StandardError => error
              error
            end
          end
        end

        2.times { ready.pop }
        2.times { start << true }
        results = results.map(&:value)

        assert results.all? { |result| result.is_a?(Core::BaseService::Result) },
          results.reject { |result| result.is_a?(Core::BaseService::Result) }
            .map { |result| "#{result.class}: #{result.message}" }
            .join(", ")
        assert_equal 1, results.count(&:success?)
        conflict = results.find(&:failure?)
        assert_equal "idempotency_conflict", conflict.error.code
      ensure
        remove_registration_insert_delay
      end

      private

      def create_ticket_type
        Catalog::Products::CreateDraft.call(
          event: @event,
          actor: core_users(:super_admin),
          product_attributes: { name: "Concurrent registration ticket #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
          },
          inventory_configuration: { mode: "unlimited" }
        ).value.ticket_type
      end

      def create_required_form
        form = RegistrationForm.create!(event: @event, name: "Concurrent registration form #{SecureRandom.hex(4)}", active: true)
        version = form.versions.create!(version: 1, status: "draft")
        question = version.questions.create!(
          key: "name",
          type: "short_text",
          response_scope: "registration",
          sensitivity: "standard",
          label: "Name",
          required: true,
          position: 0,
          options: [],
          validation_rules: {}
        )
        version.update!(status: "published", published_by: core_users(:super_admin), published_at: Time.current)
        [ form, question ]
      end

      def cleanup_concurrent_records
        return unless @ticket_type

        ticket_type_ids = [ @ticket_type, @other_ticket_type ].compact.map(&:id)
        registration_ids = Registration.where(ticket_type_id: ticket_type_ids).select(:id)
        form_ids = [ @form&.id ].compact
        Registration.connection.disable_referential_integrity do
          RegistrationAnswer.joins(:registration_form_submission)
            .where(ticketing_registration_form_submissions: { registration_id: registration_ids })
            .delete_all
          RegistrationFormSubmission.where(registration_id: registration_ids).delete_all
          Registration.where(id: registration_ids).delete_all
          RegistrationQuestion.where(registration_form_version_id: RegistrationFormVersion.where(registration_form_id: form_ids)).delete_all
          RegistrationFormVersion.where(registration_form_id: form_ids).delete_all
          RegistrationForm.where(id: form_ids).delete_all
          Core::DataRetentionPolicy.where(id: @retention_policy&.id).delete_all
          Ticketing::TicketType.where(id: ticket_type_ids).delete_all
          Catalog::EventProduct.where(id: [ @ticket_type, @other_ticket_type ].compact.map(&:event_product_id)).delete_all
        end
      end

      def install_registration_insert_delay
        Registration.connection.execute <<~SQL
          CREATE FUNCTION test_registration_idempotency_insert_delay()
          RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            PERFORM pg_sleep(0.2);
            RETURN NEW;
          END;
          $$;
        SQL
        Registration.connection.execute <<~SQL
          CREATE TRIGGER test_registration_idempotency_insert_delay
          BEFORE INSERT ON ticketing_registrations
          FOR EACH ROW EXECUTE FUNCTION test_registration_idempotency_insert_delay();
        SQL
      end

      def remove_registration_insert_delay
        Registration.connection.execute("DROP TRIGGER IF EXISTS test_registration_idempotency_insert_delay ON ticketing_registrations")
        Registration.connection.execute("DROP FUNCTION IF EXISTS test_registration_idempotency_insert_delay()")
      end
    end
  end
end
