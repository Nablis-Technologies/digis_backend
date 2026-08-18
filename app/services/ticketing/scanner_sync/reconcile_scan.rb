# frozen_string_literal: true

module Ticketing
  module ScannerSync
    # Reconciles one device-produced scan against current server records. The
    # scanner's reported result is advisory; Admissions::Consume revalidates
    # the credential, current revocations, zone scope, and usage ceiling.
    class ReconcileScan < Core::BaseService
      def initialize(assignment:, operator:, upload:, attributes:, received_at: Time.current)
        @assignment = assignment
        @operator = operator
        @upload = upload
        @attributes = attributes.to_h.symbolize_keys
        @received_at = received_at
      end

      def call
        scan = normalized_scan
        return failure(scan) if scan.is_a?(Core::Error)

        credential = find_credential(scan)
        return failure(error(:credential_not_found, :not_found)) unless credential
        return failure(error(:scan_upload_credential_mismatch, :unprocessable_entity)) unless
          credential.ticket_id.to_s == scan.fetch(:ticket_id)

        product_access = Catalog::ProductAccess.find_by(id: scan.fetch(:product_access_id))
        return failure(error(:product_access_not_found, :not_found)) unless product_access

        access_zone = find_access_zone(scan)
        return failure(access_zone) if access_zone.is_a?(Core::Error)

        identity_checker = find_identity_checker(scan)
        return failure(identity_checker) if identity_checker.is_a?(Core::Error)

        result = Ticketing::Admissions::Consume.call(
          claims: claims_for(credential, scan),
          product_access:,
          assignment: @assignment,
          access_zone:,
          scan_upload: @upload,
          client_scan_id: scan.fetch(:client_scan_id),
          scanned_at: scan.fetch(:scanned_at),
          lookup_via: scan.fetch(:lookup_via),
          reason_code: scan[:reason_code],
          identity_check: identity_check(scan),
          identity_checked_by: identity_checker,
          now: scan.fetch(:scanned_at),
          received_at: @received_at
        )
        return failure(result.error) if result.failure?

        success(Ticketing::CheckinLog.includes(:admission_uses).find(result.value.id))
      rescue ActiveRecord::RecordInvalid => exception
        failure(
          error(
            :admission_record_invalid,
            :unprocessable_entity,
            errors: exception.record.errors.to_hash
          )
        )
      rescue ArgumentError, KeyError, TypeError
        failure(error(:scanner_upload_scan_invalid, :unprocessable_entity))
      end

      private

      def normalized_scan
        required = %i[client_scan_id credential_id ticket_id product_access_id credential_version scanned_at]
        return error(:scanner_upload_scan_invalid, :unprocessable_entity) unless required.all? { |key| @attributes.key?(key) }

        values = @attributes.slice(
          :client_scan_id, :credential_id, :ticket_id, :product_access_id, :access_zone_id,
          :credential_version, :scanned_at, :lookup_via, :reason_code,
          :identity_check_result, :identity_checked_by_id
        )
        uuid_keys = %i[client_scan_id credential_id ticket_id product_access_id access_zone_id identity_checked_by_id]
        uuid_keys.each do |key|
          next if values[key].blank? && %i[access_zone_id identity_checked_by_id].include?(key)
          return error(:scanner_upload_scan_invalid, :unprocessable_entity) unless uuid?(values[key])

          values[key] = values[key].to_s
        end
        values[:credential_version] = Integer(values.fetch(:credential_version))
        return error(:scanner_upload_scan_invalid, :unprocessable_entity) unless values[:credential_version].positive?

        values[:scanned_at] = parse_time(values.fetch(:scanned_at))
        values[:lookup_via] = values[:lookup_via].presence || "qr"
        values[:identity_check_result] = values[:identity_check_result].presence || "not_required"
        return error(:scanner_upload_scan_invalid, :unprocessable_entity) unless
          Ticketing::CheckinLog::LOOKUP_METHODS.include?(values[:lookup_via]) &&
          Ticketing::CheckinLog::IDENTITY_RESULTS.include?(values[:identity_check_result])

        values
      rescue ArgumentError, TypeError
        error(:scanner_upload_scan_invalid, :unprocessable_entity)
      end

      def find_credential(scan)
        Ticketing::Credential.includes(
          :credential_generation,
          ticket: { event_product: { product_accesses: :event_date } }
        ).find_by(id: scan.fetch(:credential_id))
      end

      def find_access_zone(scan)
        return unless scan[:access_zone_id]

        Events::AccessZone.find_by(id: scan[:access_zone_id]) ||
          error(:zone_not_found, :unprocessable_entity)
      end

      def find_identity_checker(scan)
        return if scan.fetch(:identity_check_result) == "not_required"
        return error(:identity_checker_not_found, :unprocessable_entity) unless @operator
        return error(:identity_checker_mismatch, :unprocessable_entity) unless
          scan[:identity_checked_by_id].to_s == @operator.id.to_s

        @operator
      end

      def identity_check(scan)
        result = scan.fetch(:identity_check_result)
        return if result == "not_required"

        result
      end

      def claims_for(credential, scan)
        generation = credential.credential_generation
        product_accesses = credential.ticket.event_product.product_accesses
        Ticketing::CredentialClaims.from_h(
          kid: Rails.application.config.x.ticketing_qr_current_kid.to_s,
          cid: credential.id.to_s,
          tid: credential.ticket_id.to_s,
          eid: credential.event_id.to_s,
          mode: credential.type == "package" ? "group" : "individual",
          slots: Array(credential.slot_positions).map(&:to_i),
          entry_limit: credential.entry_limit,
          v: scan.fetch(:credential_version),
          accesses: product_accesses.map { |access| access.id.to_s },
          exp: product_accesses.map { |access| access.event_date.ends_at.to_i }.max
        )
      end

      def parse_time(value)
        return value if value.is_a?(Time)

        Time.zone.parse(value.to_s)
      end

      def uuid?(value)
        value.to_s.match?(Ticketing::ScannerSync::ProcessUpload::UUID_PATTERN)
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
