# frozen_string_literal: true

require "digest"

module Messaging
  module Campaigns
    module ContactLists
      # Creates an asynchronous, idempotent import for an attached CSV blob.
      class Import < Core::BaseService
        MAX_FILE_BYTES = 5.megabytes
        ALLOWED_CONTENT_TYPES = %w[text/csv application/csv application/vnd.ms-excel].freeze

        def initialize(list:, blob:, actor:, idempotency_key:)
          @list = list
          @blob = blob
          @actor = actor
          @raw_idempotency_key = idempotency_key
        end

        def call
          key = Core::IdempotencyKey.new(@raw_idempotency_key)
          return failure_for(:contact_list_file_required) unless @blob.is_a?(ActiveStorage::Blob)
          return failure_for(:contact_list_file_too_large) if @blob.byte_size > MAX_FILE_BYTES
          return failure_for(:contact_list_file_type_invalid) unless ALLOWED_CONTENT_TYPES.include?(@blob.content_type.to_s)

          request_digest = Core::KeyedDigest.digest(
            namespace: "messaging-campaign-contact-list-import-request",
            value: "#{@list.id}:#{@blob.id}:#{@blob.checksum}"
          )
          existing = @list.imports.find_by(idempotency_key_digest: key.digest)
          if existing
            return failure_for(:idempotency_conflict, status: :conflict) unless existing.request_digest == request_digest

            return success(existing)
          end

          import = @list.imports.create!(
            created_by: @actor,
            status: "pending",
            filename: @blob.filename.to_s,
            idempotency_key_digest: key.digest,
            request_digest:
          )
          import.file.attach(@blob)
          ImportCampaignContactListJob.perform_later(import.id)
          success(import)
        rescue ArgumentError => exception
          failure(Core::BusinessError.new(exception.message, code: "invalid_idempotency_key", status: :bad_request))
        rescue ActiveRecord::RecordInvalid => exception
          failure(error(:contact_list_invalid, errors: exception.record.errors.to_hash))
        rescue ActiveRecord::RecordNotUnique
          failure_for(:idempotency_conflict, status: :conflict)
        end

        private

        def failure_for(key, status: :unprocessable_entity)
          failure(error(key, status:))
        end

        def error(key, status: :unprocessable_entity, errors: nil)
          Core::BusinessError.new(I18n.t("messaging.errors.#{key}"), code: key.to_s, status:, errors:)
        end
      end
    end
  end
end
