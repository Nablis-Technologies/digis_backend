# frozen_string_literal: true

module Ticketing
  module AttendeeExportTestHelpers
    def create_export(event:, actor:, overrides: {})
      now = Time.current
      attributes = {
        event:,
        requested_by: actor,
        status: "pending",
        row_mode: "registration",
        format_version: "csv_v1",
        field_keys: [ "registration_id" ],
        filters: {},
        field_set_digest: "a" * 64,
        filter_digest: "b" * 64,
        reason_code: "event_operations",
        data_cutoff_at: now,
        expires_at: now + 24.hours,
        idempotency_key_digest: SecureRandom.hex(32),
        request_fingerprint: SecureRandom.hex(32),
        digest_key_version: "v1",
        attempt_count: 0,
        lock_version: 0
      }
      attributes[:row_count] = 1 if overrides[:status] == "ready"
      attributes[:file_sha256] = "f" * 64 if overrides[:status] == "ready"
      attributes.merge!(lifecycle_attributes(attributes, overrides))
      Ticketing::AttendeeExport.create!(attributes.merge(overrides.except(:status, :processing_started_at,
        :ready_at, :failed_at, :expiring_at, :expired_at, :failure_code)))
    end

    def create_export_ticket_type(event, name: "Export ticket", admissions_per_unit: 1)
      Catalog::Products::CreateDraft.call(
        event:,
        actor: core_users(:super_admin),
        product_attributes: { name: "#{name} #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit:
        },
        inventory_configuration: { mode: "unlimited" }
      ).value.ticket_type
    end

    def create_export_registration(event, ticket_type, user: core_users(:attendee), status: "confirmed",
      package_quantity: 1)
      Ticketing::Registration.create!(
        event:,
        ticket_type:,
        user:,
        created_by: user,
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity:,
        admissions_per_unit_snapshot: ticket_type.admissions_per_unit,
        party_size: package_quantity * ticket_type.admissions_per_unit,
        status:,
        submitted_at: Time.current
      )
    end

    def create_export_answer(registration:, key: "formula", value: "=2+2", answered_at: Time.current,
      retention_days: 30)
      policy = Core::DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 1,
        retention_days:,
        action: "erase_payload",
        status: "active",
        effective_at: answered_at - 1.day,
        created_by: core_users(:super_admin)
      )
      form = Ticketing::RegistrationForm.create!(event: registration.event, name: "Export form #{SecureRandom.hex(4)}", active: true)
      version = form.versions.create!(version: 1, status: "draft")
      question = version.questions.create!(
        key:,
        type: "short_text",
        response_scope: "registration",
        sensitivity: "standard",
        label: key.humanize,
        position: 0,
        options: [],
        validation_rules: {}
      )
      version.update!(status: "published", published_by: core_users(:super_admin), published_at: Time.current)
      submission = registration.form_submissions.create!(
        registration_form_version: version,
        submitted_by_user: registration.user,
        submitted_at: answered_at
      )
      answer = submission.answers.create!(
        registration_question: question,
        question_key_snapshot: question.key,
        question_type_snapshot: question.type,
        response_scope_snapshot: question.response_scope,
        question_label_snapshot: question.label,
        answer: value,
        retention_policy: policy,
        retain_until: answered_at + policy.retention_days.days,
        answered_at:
      )
      [ answer, "question:#{form.id}:#{key}" ]
    end

    private

    def lifecycle_attributes(attributes, overrides)
      status = overrides.fetch(:status, attributes.fetch(:status))
      now = Time.current
      timestamps = {
        processing_started_at: %w[processing ready failed].include?(status) ? now : nil,
        ready_at: status == "ready" ? now : nil,
        failed_at: status == "failed" ? now : nil,
        expiring_at: status == "expiring" ? now : nil,
        expired_at: status == "expired" ? now : nil,
        failure_code: status == "failed" ? "export_generation_failed" : nil
      }
      timestamps.merge(overrides.slice(:status, :processing_started_at, :ready_at, :failed_at,
        :expiring_at, :expired_at, :failure_code))
    end
  end
end
