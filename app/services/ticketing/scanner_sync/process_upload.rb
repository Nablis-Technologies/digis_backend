# frozen_string_literal: true

module Ticketing
  module ScannerSync
    # Owns one device-scoped offline batch. The upload row and all nested scan
    # decisions commit together; the completed response is an immutable replay
    # boundary for retries after revocations or usage state have changed.
    class ProcessUpload < Core::BaseService
      MAX_SCANS = 500
      UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      MAX_UNIQUE_RETRIES = 3

      def initialize(assignment:, operator:, client_upload_id:, scans:, cursors:, received_at: Time.current)
        @assignment = assignment
        @operator = operator
        @client_upload_id = client_upload_id
        @scans = scans
        @cursors = cursors
        @received_at = received_at
      end

      def call
        return failure(error(:scanner_batch_too_large, :content_too_large)) if Array(@scans).length > MAX_SCANS

        normalized = normalize_inputs
        return failure(normalized) if normalized.is_a?(Core::Error)

        @normalized_scans, @client_upload_id = normalized
        process_with_unique_retry
      end

      private

      def process_with_unique_retry
        attempts = 0
        begin
          attempts += 1
          process_once
        rescue ActiveRecord::RecordNotUnique
          retry if attempts < MAX_UNIQUE_RETRIES

          failure(error(:scanner_upload_conflict, :conflict))
        end
      end

      def process_once
        outcome = nil
        Ticketing::ApplicationRecord.transaction do
          assignment = Ticketing::ScannerDeviceAssignment.lock.find(@assignment.id)
          upload = Ticketing::ScanUpload.lock.find_or_create_by!(
            scanner_device_assignment: assignment,
            client_upload_id: @client_upload_id
          ) do |new_upload|
            new_upload.received_at = @received_at
          end

          if upload.completed_at?
            outcome = success(upload.results_snapshot.deep_dup)
            next
          end

          prior_checkins = prior_checkins_by_scan_id
          results = @normalized_scans.map do |attributes|
            prior = prior_checkins[attributes.fetch(:client_scan_id)]
            next prior.serialized_result if prior

            result = Ticketing::ScannerSync::ReconcileScan.call(
              assignment:,
              operator: @operator,
              upload:,
              attributes:,
              received_at: @received_at
            )
            raise result.error if result.failure?

            result.value.serialized_result
          end

          sync = Ticketing::ScannerSync::BuildDelta.call(
            assignment:,
            cursors: @cursors
          )
          raise sync.error if sync.failure?

          snapshot = {
            "results" => results,
            "sync" => Ticketing::ScannerSyncSerializer.call(sync.value)
          }
          upload.update!(completed_at: Time.current, results_snapshot: snapshot)
          outcome = success(snapshot)
        end
        outcome
      rescue Core::Error => exception
        failure(exception)
      rescue ActiveRecord::RecordInvalid => exception
        failure(
          error(
            :admission_record_invalid,
            :unprocessable_entity,
            errors: exception.record.errors.to_hash
          )
        )
      end

      def normalize_inputs
        return error(:scanner_upload_parameters_invalid, :bad_request) unless uuid?(@client_upload_id)
        return error(:scanner_upload_parameters_invalid, :bad_request) unless @scans.is_a?(Array)

        normalized_scans = @scans.map do |scan|
          return error(:scanner_upload_scan_invalid, :unprocessable_entity) unless scan.respond_to?(:to_h)

          scan.to_h.deep_symbolize_keys
        end
        [ normalized_scans, @client_upload_id.to_s ]
      end

      def prior_checkins_by_scan_id
        ids = @normalized_scans.map { |attributes| attributes.fetch(:client_scan_id) }
        return {} if ids.empty?

        Ticketing::CheckinLog.includes(:admission_uses)
          .where(client_scan_id: ids)
          .index_by(&:client_scan_id)
      end

      def uuid?(value)
        value.to_s.match?(UUID_PATTERN)
      end

      def error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.scanner_sync.errors.#{key}"),
          code: key,
          status:,
          errors:
        )
      end
    end
  end
end
