# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Exports
    class FieldRegistryTest < ActiveSupport::TestCase
      ExportRow = Struct.new(
        :registration,
        :answer_by_selector,
        :package_unit_number,
        :admission_position,
        keyword_init: true
      )

      setup do
        @event = events_events(:ready_listing)
        @user = core_users(:attendee)
        @ticket_type = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: core_users(:super_admin),
          product_attributes: { name: "Export registry ticket", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed",
            admissions_per_unit: 2
          },
          inventory_configuration: { mode: "unlimited" }
        ).value.ticket_type
        @registration = Ticketing::Registration.create!(
          event: @event,
          ticket_type: @ticket_type,
          user: @user,
          created_by: @user,
          source: "self_service",
          identity_digest: "e" * 64,
          package_quantity: 2,
          admissions_per_unit_snapshot: 2,
          party_size: 4,
          status: "confirmed",
          submitted_at: Time.current
        )
        @form = Ticketing::RegistrationForm.create!(
          event: @event,
          name: "Export questions",
          active: true
        )
      end

      test "exposes only the fixed built-ins with their authorization and row modes" do
        expected = {
          "registration_id" => [ :event_manager, %w[registration admission] ],
          "registration_status" => [ :event_manager, %w[registration admission] ],
          "ticket_type_id" => [ :event_manager, %w[registration admission] ],
          "selected_event_date_id" => [ :event_manager, %w[registration admission] ],
          "package_unit_number" => [ :event_manager, [ "admission" ] ],
          "admission_position" => [ :event_manager, [ "admission" ] ],
          "registration_user_email" => [ "attendee_export.contact", %w[registration admission] ],
          "registration_user_phone" => [ "attendee_export.contact", %w[registration admission] ]
        }

        definitions = resolve!(expected.keys, row_mode: "admission")
        assert_equal expected.keys, definitions.map { |definition| definition.fetch(:selector) }

        definitions.each do |definition|
          authorization, row_modes = expected.fetch(definition.fetch(:selector))
          assert_equal authorization, definition.fetch(:authorization)
          assert_equal row_modes, definition.fetch(:row_modes)
          assert_equal I18n.t("ticketing.attendee_exports.fields.#{definition.fetch(:selector)}"), definition.fetch(:heading)
          assert_respond_to definition.fetch(:extractor), :call
        end
      end

      test "fixed built-in extractors emit every column and repeat registration contact across coordinates" do
        row_one = ExportRow.new(
          registration: @registration,
          answer_by_selector: {},
          package_unit_number: 1,
          admission_position: 1
        )
        row_two = ExportRow.new(
          registration: @registration,
          answer_by_selector: {},
          package_unit_number: 2,
          admission_position: 2
        )
        expected = {
          "registration_id" => @registration.id,
          "registration_status" => @registration.status,
          "ticket_type_id" => @registration.ticket_type_id,
          "selected_event_date_id" => @registration.selected_event_date_id,
          "package_unit_number" => 1,
          "admission_position" => 1,
          "registration_user_email" => @registration.user.email,
          "registration_user_phone" => @registration.user.phone
        }
        definitions = resolve!(expected.keys, row_mode: "admission").index_by { |definition| definition.fetch(:selector) }

        expected.each do |selector, value|
          actual = definitions.fetch(selector).fetch(:extractor).call(row_one)
          value.nil? ? assert_nil(actual, selector) : assert_equal(value, actual, selector)
        end
        assert_equal 2, definitions.fetch("package_unit_number").fetch(:extractor).call(row_two)
        assert_equal 2, definitions.fetch("admission_position").fetch(:extractor).call(row_two)
        assert_equal @registration.user.email,
                     definitions.fetch("registration_user_email").fetch(:extractor).call(row_two)
        assert_equal @registration.user.phone,
                     definitions.fetch("registration_user_phone").fetch(:extractor).call(row_two)
        refute_equal row_one.package_unit_number, row_two.package_unit_number
        refute_equal row_one.admission_position, row_two.admission_position
      end

      test "registration rows exclude admission-only built-ins" do
        selectors = %w[
          registration_id registration_status ticket_type_id selected_event_date_id
          registration_user_email registration_user_phone
        ]

        definitions = resolve!(selectors, row_mode: "registration")
        assert_equal selectors, definitions.map { |definition| definition.fetch(:selector) }
      end

      test "rejects admission-only built-ins in registration rows" do
        result = resolve_result(%w[package_unit_number admission_position], row_mode: "registration")

        assert_predicate result, :failure?
      end

      test "rejects selector values that attempt to provide SQL, method, heading, path, or extractors" do
        [
          "sql:users.email",
          "method:user.email",
          "heading:Email",
          "path:user.email",
          "extractor:registration.user.email"
        ].each do |selector|
          result = resolve_result([ selector ])

          assert_predicate result, :failure?
        end
      end

      test "rejects unimplemented assigned-attendee contact selectors" do
        result = resolve_result([ "assigned_attendee_email" ])

        assert_predicate result, :failure?
      end

      test "marks standard fields as event-scoped and contact fields as explicitly gated" do
        standard = definition_for("registration_id")
        contact = definition_for("registration_user_email")

        assert_equal :event_manager, standard.fetch(:authorization)
        assert_equal "attendee_export.contact", contact.fetch(:authorization)
        refute_equal standard.fetch(:authorization), contact.fetch(:authorization)
      end

      test "assigns dietary and accessibility questions to their narrow permissions" do
        dietary = publish_question(key: "meal", sensitivity: "dietary")
        accessibility = publish_question(key: "mobility", sensitivity: "accessibility")

        assert_equal "attendee_export.dietary", definition_for(question_selector(dietary)).fetch(:authorization)
        assert_equal "attendee_export.accessibility", definition_for(question_selector(accessibility)).fetch(:authorization)
      end

      test "allows registration questions in registration rows and admission rows" do
        registration_question = publish_question(key: "name", response_scope: "registration")

        assert_predicate resolve_result([ question_selector(registration_question) ], row_mode: "registration"), :success?
        assert_predicate resolve_result([ question_selector(registration_question) ], row_mode: "admission"), :success?
      end

      test "rejects admission-scope questions in registration rows" do
        admission_question = publish_question(key: "seat", response_scope: "admission_slot")
        result = resolve_result([ question_selector(admission_question) ], row_mode: "registration")

        assert_predicate result, :failure?
      end

      test "allows admission-scope questions in admission rows" do
        admission_question = publish_question(key: "seat", response_scope: "admission_slot")
        result = resolve_result([ question_selector(admission_question) ], row_mode: "admission")

        assert_predicate result, :success?
        assert_equal "seat", result.value.sole.fetch(:selector).split(":").last
      end

      test "normalizes Unicode text and ignores position and database identity changes" do
        first = travel_to(Time.utc(2025, 1, 1)) do
          publish_question(
            version_number: 1,
            key: "meal",
            label: " \u0065\u0301\u2003Meal ",
            help_text: " Choose\u00a0one ",
            position: 1,
            options: [
              { "key" => "vegetarian", "label" => " Vegetarian " },
              { "key" => "standard", "label" => "Standard" }
            ],
            validation_rules: {
              "max_items" => 2,
              "allowed_option_keys" => [ "standard", "vegetarian" ],
              "min_items" => 1
            },
            type: "multiple_choice"
          )
        end
        second = travel_to(Time.utc(2026, 1, 1)) do
          publish_question(
            version_number: 2,
            key: "meal",
            label: "\u00e9 Meal",
            help_text: "Choose one",
            position: 9,
            options: [
              { "key" => "standard", "label" => "Standard" },
              { "key" => "vegetarian", "label" => "Vegetarian" }
            ],
            validation_rules: {
              "min_items" => 1,
              "allowed_option_keys" => [ "vegetarian", "standard" ],
              "max_items" => 2
            },
            type: "multiple_choice"
          )
        end

        refute_equal first.id, second.id
        refute_equal first.registration_form_version_id, second.registration_form_version_id
        refute_equal first.created_at, second.created_at
        refute_equal first.registration_form_version.created_at, second.registration_form_version.created_at
        assert_predicate resolve_result([ question_selector(first) ]), :success?
      end

      test "canonicalizes validation rule keys but preserves semantic validation changes" do
        first = publish_question(
          version_number: 1,
          key: "name",
          type: "short_text",
          validation_rules: { "max_length" => 120, "min_length" => 2 }
        )
        equivalent = publish_question(
          version_number: 2,
          key: "name",
          type: "short_text",
          validation_rules: { "min_length" => 2, "max_length" => 120 }
        )

        assert_predicate resolve_result([ question_selector(first) ]), :success?

        changed = publish_question(
          version_number: 3,
          key: "name",
          type: "short_text",
          validation_rules: { "min_length" => 3, "max_length" => 120 }
        )
        result = resolve_result([ question_selector(changed) ])

        assert_predicate result, :failure?
        assert_equal "field_definition_conflict", result.error.code
      end

      test "rejects changed wording and choice meaning across submitted immutable versions" do
        first = publish_question(
          version_number: 1,
          key: "meal",
          type: "single_choice",
          label: "Meal",
          options: [ { "key" => "standard", "label" => "Standard" } ]
        )
        publish_question(
          version_number: 2,
          key: "meal",
          type: "single_choice",
          label: "Preferred meal",
          options: [ { "key" => "standard", "label" => "Standard" } ]
        )

        wording_conflict = resolve_result([ question_selector(first) ])
        assert_predicate wording_conflict, :failure?
        assert_equal "field_definition_conflict", wording_conflict.error.code

        @form = Ticketing::RegistrationForm.create!(event: @event, name: "Choice conflict", active: true)
        first_choice = publish_question(
          version_number: 1,
          key: "meal",
          type: "single_choice",
          options: [ { "key" => "standard", "label" => "Standard" } ]
        )
        publish_question(
          version_number: 2,
          key: "meal",
          type: "single_choice",
          options: [ { "key" => "standard", "label" => "Premium" } ]
        )

        choice_conflict = resolve_result([ question_selector(first_choice) ])
        assert_predicate choice_conflict, :failure?
        assert_equal "field_definition_conflict", choice_conflict.error.code
      end

      test "rejects a changed question type" do
        assert_semantic_conflict(base: { type: "short_text" }, changed: { type: "long_text" })
      end

      test "rejects a changed question response scope" do
        assert_semantic_conflict(
          base: { response_scope: "registration" },
          changed: { response_scope: "admission_slot" }
        )
      end

      test "rejects a changed question sensitivity" do
        assert_semantic_conflict(base: { sensitivity: "standard" }, changed: { sensitivity: "dietary" })
      end

      test "rejects a changed question requiredness" do
        assert_semantic_conflict(base: { required: false }, changed: { required: true })
      end

      test "accepts a selector when a submitted historical version lacks the question and leaves its cell empty" do
        question = publish_question(version_number: 1, key: "name", type: "short_text")
        version_without_question = publish_version(version_number: 2)
        submit(version_without_question)

        result = resolve_result([ question_selector(question) ])

        assert_predicate result, :success?
        field = result.value.sole
        row = ExportRow.new(
          registration: @registration,
          answer_by_selector: {},
          package_unit_number: 1,
          admission_position: 1
        )
        assert_nil field.fetch(:extractor).call(row)
      end

      private

      def resolve!(selectors, row_mode: "registration")
        result = resolve_result(selectors, row_mode:)
        assert_predicate result, :success?
        result.value
      end

      def resolve_result(selectors, row_mode: "registration")
        Ticketing::Exports::FieldRegistry.resolve(
          event: @event,
          selectors:,
          row_mode:
        )
      end

      def definition_for(selector, row_mode: "registration")
        resolve!([ selector ], row_mode:).sole
      end

      def question_selector(question)
        "question:#{question.registration_form_version.registration_form_id}:#{question.key}"
      end

      def publish_question(version_number: next_version, **overrides)
        version = @form.versions.create!(version: version_number, status: "draft")
        question = version.questions.create!(question_attributes(overrides))
        publish(version)
        submit(version)
        question
      end

      def publish_version(version_number: next_version)
        version = @form.versions.create!(version: version_number, status: "draft")
        publish(version)
        version
      end

      def publish(version)
        @form.versions.where(status: "published").find_each { |published| published.update!(status: "retired") }
        version.update!(status: "published", published_by: core_users(:super_admin), published_at: Time.current)
      end

      def submit(version)
        @registration.form_submissions.create!(
          registration_form_version: version,
          submitted_by_user: @user,
          submitted_at: Time.current
        )
      end

      def next_version
        @form.versions.maximum(:version).to_i + 1
      end

      def question_attributes(overrides)
        {
          key: "question",
          type: "short_text",
          response_scope: "registration",
          sensitivity: "standard",
          label: "Question",
          help_text: nil,
          required: false,
          position: 0,
          options: [],
          validation_rules: {}
        }.merge(overrides)
      end

      def assert_semantic_conflict(base:, changed:)
        @form = Ticketing::RegistrationForm.create!(
          event: @event,
          name: "Definition conflict #{SecureRandom.hex(4)}",
          active: true
        )
        first = publish_question(version_number: 1, key: "profile", **base)
        publish_question(version_number: 2, key: "profile", **base.merge(changed))

        result = resolve_result([ question_selector(first) ])

        assert_predicate result, :failure?
        assert_equal "field_definition_conflict", result.error.code
      end
    end
  end
end
