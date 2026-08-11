# frozen_string_literal: true

require "csv"
require "digest"
require "tempfile"

module Ticketing
  module Exports
    # Claims one export attempt, writes bounded CSV outside the row lock, then
    # finalizes only if the same attempt and authorization still hold.
    class Generate < Core::BaseService
      BATCH_SIZE = 1_000
      MAX_COLUMNS = 100
      MAX_ROWS = 250_000
      MAX_BYTES = 512 * 1024 * 1024
      LEASE = 15.minutes

      Row = Struct.new(:registration, :package_unit_number, :admission_position, :answers, keyword_init: true) do
        def answer_by_selector = answers
      end

      class TooLarge < StandardError; end

      def initialize(attendee_export_id:)
        @attendee_export_id = attendee_export_id
      end

      def call
        @earliest_retain_until = nil
        claim = claim_export
        if claim.is_a?(Core::BaseService::Result)
          purge_partial_file(claim.value.id) if claim.success? && claim.value&.status == "failed"
          return claim
        end

        Tempfile.create([ "attendee-export-", ".csv" ]) do |file|
          file.binmode
          artifact = write_csv(claim.export, file)
          attach_file(claim.export, file)
          finalized = finalize_export(claim.export.id, claim.attempt, artifact)
          unless finalized
            purge_partial_file(claim.export.id)
            fail_export("export_generation_failed", attempt: claim.attempt)
          end
        end

        success(Ticketing::AttendeeExport.find(@attendee_export_id))
      rescue TooLarge
        success(fail_export("export_too_large"))
      rescue ActiveStorage::Error, IOError, SystemCallError
        success(fail_export("export_storage_unavailable"))
      rescue StandardError
        success(fail_export("export_generation_failed"))
      end

      private

      Claim = Struct.new(:export, :attempt, keyword_init: true)
      Artifact = Struct.new(:row_count, :bytes, :sha256, keyword_init: true)

      def claim_export
        AttendeeExport.transaction do
          event_id = AttendeeExport.where(id: @attendee_export_id).pick(:event_id)
          return failure(not_found_error) unless event_id

          Core::Database::AdvisoryLock.acquire!("registration-privacy-event", event_id)
          export = AttendeeExport.lock.find(@attendee_export_id)
          return success(export) if %w[ready failed expiring expired].include?(export.status)
          return success(export) if export.status == "processing" && !stale?(export)

          if export.attempt_count >= 3
            fail_export_record!(export, "export_generation_failed")
            return success(export)
          end

          unless authorized?(export)
            fail_export_record!(export, "export_generation_failed")
            return success(export)
          end

          attempt = export.attempt_count + 1
          export.update!(status: "processing", processing_started_at: Time.current, attempt_count: attempt)
          Claim.new(export: export.reload, attempt:)
        end
      end

      def authorized?(export)
        Ticketing::AttendeeExportPolicy.new(export.requested_by, export).create?
      end

      def stale?(export)
        export.processing_started_at.blank? || export.processing_started_at <= LEASE.ago
      end

      def write_csv(export, file)
        definitions_result = FieldRegistry.resolve(
          event: export.event,
          selectors: export.field_keys,
          row_mode: export.row_mode
        )
        raise StandardError, definitions_result.error.message if definitions_result.failure?

        definitions = definitions_result.value
        raise TooLarge if definitions.length > MAX_COLUMNS

        csv = CSV.new(file, row_sep: "\r\n")
        csv << definitions.map { |definition| definition.fetch(:heading) }
        row_count = 0

        registration_relation(export).find_in_batches(batch_size: BATCH_SIZE) do |registrations|
          registrations.each do |registration|
            next unless matches_filters?(registration, export.filters)

            answers = answer_index(registration, export.data_cutoff_at)
            rows_for(registration, export.row_mode, answers).each do |row|
              row_count += 1
              raise TooLarge if row_count > MAX_ROWS

              csv << definitions.map { |definition| safe_cell(definition.fetch(:extractor).call(row)) }
              file.flush
              raise TooLarge if file.size > MAX_BYTES
            end
          end
        end

        file.flush
        file.rewind
        Artifact.new(row_count:, bytes: file.size, sha256: Digest::SHA256.file(file.path).hexdigest)
      end

      def registration_relation(export)
        Ticketing::Registration
          .where(event_id: export.event_id)
          .where("ticketing_registrations.created_at <= ?", export.data_cutoff_at)
          .includes(
            :user,
            ticket_type: { event_product: { product_accesses: :event_date } },
            form_submissions: {
              registration_form_version: :registration_form,
              answers: :revisions
            }
          )
          .order(:id)
      end

      def matches_filters?(registration, filters)
        filters = filters || {}
        return false unless matches_values?(registration.ticket_type_id, filter_values(filters, "ticket_type_ids"))
        return false unless matches_values?(registration.status, filter_values(filters, "registration_statuses"))

        date_filter_matches?(registration, filter_values(filters, "access_event_date_ids"))
      end

      def matches_values?(value, values)
        values.blank? || values.include?(value.to_s)
      end

      def date_filter_matches?(registration, values)
        return true if values.blank?
        return values.include?(registration.selected_event_date_id.to_s) if registration.ticket_type.date_selection == "choose_one"

        access_ids = registration.ticket_type.event_product.product_accesses.map(&:event_date_id).map(&:to_s)
        (access_ids & values).any?
      end

      def filter_values(filters, key)
        filters[key] || filters[key.to_sym]
      end

      def answer_index(registration, cutoff)
        registration.form_submissions.each_with_object({}) do |submission, result|
          form_id = submission.registration_form_version.registration_form_id
          submission.answers.each do |answer|
            value = effective_answer(answer, cutoff)
            next if value.nil?

            selector = "question:#{form_id}:#{answer.question_key_snapshot}"
            result[[ selector, answer.package_unit_number, answer.admission_position ]] = value
          end
        end
      end

      def effective_answer(answer, cutoff)
        return if answer.erased? || answer.answered_at > cutoff
        return if answer.retain_until.present? && answer.retain_until <= Time.current

        @earliest_retain_until = [ @earliest_retain_until, answer.retain_until ].compact.min

        revision = answer.revisions
          .reject { |candidate| candidate.erased? || candidate.revised_at > cutoff }
          .reject { |candidate| candidate.retain_until.present? && candidate.retain_until <= Time.current }
          .max_by(&:revision_number)
        revision ? revision.answer : answer.answer
      end

      def rows_for(registration, row_mode, answers)
        return [ Row.new(registration:, answers: answer_values_for(answers, nil, nil)) ] if row_mode == "registration"

        1.upto(registration.package_quantity).flat_map do |unit|
          1.upto(registration.admissions_per_unit_snapshot).map do |position|
            Row.new(
              registration:,
              package_unit_number: unit,
              admission_position: position,
              answers: answer_values_for(answers, unit, position)
            )
          end
        end
      end

      def answer_values_for(answers, package_unit_number, admission_position)
        answers.each_with_object({}) do |((selector, unit, position), value), result|
          next unless [ unit, position ] == [ nil, nil ] || [ unit, position ] == [ package_unit_number, admission_position ]

          result[selector] = value
        end
      end

      def safe_cell(value)
        value = case value
        when Array, Hash then JSON.generate(value)
        when Date, Time, DateTime then value.iso8601
        else value
        end
        cell = value.nil? ? "" : value.to_s
        cell.match?(/\A[=+\-@\t\r]/) ? "'#{cell}" : cell
      end

      def attach_file(export, file)
        file.rewind
        export.file.attach(
          io: file,
          filename: "attendee-export-#{export.id}.csv",
          content_type: "text/csv"
        )
      end

      def finalize_export(export_id, attempt, artifact)
        AttendeeExport.transaction do
          event_id = AttendeeExport.where(id: export_id).pick(:event_id)
          return false unless event_id

          Core::Database::AdvisoryLock.acquire!("registration-privacy-event", event_id)
          export = AttendeeExport.lock.find(export_id)
          return false unless export.status == "processing" && export.attempt_count == attempt
          return false unless authorized?(export) && export.expires_at > Time.current && export.file.attached?

          export.update!(
            status: "ready",
            row_count: artifact.row_count,
            file_sha256: artifact.sha256,
            ready_at: Time.current,
            expires_at: [ export.expires_at, @earliest_retain_until ].compact.min
          )
          record_generation_audit(export, "ready", artifact:)
          true
        end
      end

      def purge_partial_file(export_id)
        export = AttendeeExport.find_by(id: export_id)
        export&.file&.purge if export&.file&.attached?
      end

      def fail_export(code, attempt: nil)
        purge_partial_file(@attendee_export_id)
        AttendeeExport.transaction do
          export = AttendeeExport.lock.find(@attendee_export_id)
          event_id = export.event_id
          Core::Database::AdvisoryLock.acquire!("registration-privacy-event", event_id)
          if export.status == "processing"
            fail_export_record!(export, code, attempt:)
          end
          export.reload
        end
      rescue StandardError
        AttendeeExport.find_by(id: @attendee_export_id)
      end

      def fail_export_record!(export, code, attempt: nil)
        export.update!(
          status: "failed",
          processing_started_at: export.processing_started_at || Time.current,
          failed_at: Time.current,
          failure_code: code
        )
        record_generation_audit(export, "generation_failed", attempt: attempt || export.attempt_count,
          failure_code: code)
      end

      def record_generation_audit(export, status, artifact: nil, attempt: nil, failure_code: nil)
        result = Core::Audit::Record.call(
          audit_key: "ticketing-attendee-export-#{status}:#{export.id}:#{attempt || export.attempt_count}",
          action: "ticketing.attendee_export.#{status}",
          auditable_type: export.class.name,
          auditable_id: export.id,
          actor_type: "Core::User",
          actor_id: export.requested_by_id,
          metadata: {
            event_id: export.event_id,
            status: export.status,
            attempt_count: attempt || export.attempt_count,
            row_count: artifact&.row_count || export.row_count,
            byte_count: artifact&.bytes,
            failure_code:
          }.compact
        )
        raise result.error if result.failure?
      end

      def not_found_error
        Core::BusinessError.new(
          I18n.t("ticketing.attendee_exports.errors.not_found"),
          code: "export_not_found",
          status: :not_found
        )
      end
    end
  end
end
