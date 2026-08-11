# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Forms
    class PublishVersionTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
        @form = RegistrationForm.create!(event: @event, name: "Attendee details", active: true)
        @version = @form.versions.create!(version: 1, status: "draft")
        @version.questions.create!(
          key: "name",
          type: "short_text",
          response_scope: "registration",
          sensitivity: "standard",
          label: "Name",
          position: 0,
          options: [],
          validation_rules: {}
        )
      end

      test "publishes one draft and makes replay return the published version" do
        subject = -> {
          PublishVersion.call(
            version: @version,
            actor: @actor,
            idempotency_key: "publish-version-idempotent"
          )
        }

        assert_audit_idempotent(
          subject,
          action: "ticketing.registration_form_version.published",
          auditable_type: "Ticketing::RegistrationFormVersion",
          auditable_id: @version.id
        )
        result = subject.call

        assert_predicate result, :success?
        assert_predicate result.value, :published?
        assert_equal @version.id, result.value.id
        assert_equal 1, @form.reload.versions.published.count
      end

      test "replays a publish command after the version is retired" do
        key = "publish-version-late-replay"
        first = PublishVersion.call(version: @version, actor: @actor, idempotency_key: key)
        second_version = @form.versions.create!(version: 2, status: "draft")
        second_version.questions.create!(
          key: "email",
          type: "short_text",
          response_scope: "registration",
          sensitivity: "standard",
          label: "Email",
          position: 0,
          options: [],
          validation_rules: {}
        )
        PublishVersion.call(
          version: second_version,
          actor: @actor,
          idempotency_key: "publish-version-second"
        )

        replay = PublishVersion.call(version: @version, actor: @actor, idempotency_key: key)

        assert_predicate first, :success?
        assert_predicate replay, :success?
        assert_equal @version.id, replay.value.id
      end

      test "rejects an idempotency key reused for a different publish request" do
        key = "publish-version-conflict"
        first = PublishVersion.call(version: @version, actor: @actor, idempotency_key: key)
        other_version = @form.versions.create!(version: 2, status: "draft")
        other_version.questions.create!(
          key: "email",
          type: "short_text",
          response_scope: "registration",
          sensitivity: "standard",
          label: "Email",
          position: 0,
          options: [],
          validation_rules: {}
        )

        conflict = PublishVersion.call(version: other_version, actor: @actor, idempotency_key: key)

        assert_predicate first, :success?
        assert_predicate conflict, :failure?
        assert_equal "idempotency_conflict", conflict.error.code
      end

      test "rejects publication by an attendee without event management access" do
        result = PublishVersion.call(
          version: @version,
          actor: core_users(:attendee),
          idempotency_key: "publish-version-unauthorized"
        )

        assert_predicate result, :failure?
        assert_equal "not_authorized", result.error.code
      end

      test "rejects duplicate allowed option keys during publication" do
        question = @version.questions.first
        question.update_columns(
          type: "single_choice",
          options: [ { "key" => "one", "label" => "One" } ],
          validation_rules: { "allowed_option_keys" => [ "one", "one" ] }
        )

        result = PublishVersion.call(
          version: @version,
          actor: @actor,
          idempotency_key: "publish-version-duplicate-option-rules"
        )

        assert_predicate result, :failure?
        assert_equal "invalid_form_version", result.error.code
      end
    end
  end
end
