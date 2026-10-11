# frozen_string_literal: true

require "digest"

module Core
  module UserProfiles
    class AvatarUpload < Core::BaseService
      MAX_SIZE = 5.megabytes
      CONTENT_TYPES = %w[image/jpeg image/png image/webp].freeze

      Result = Data.define(:blob, :content_sha256)

      class InvalidUpload < StandardError; end
      class Unavailable < StandardError; end

      def self.fingerprint(upload)
        return if upload.blank?

        tempfile = upload.tempfile if upload.respond_to?(:tempfile)
        raise InvalidUpload unless tempfile&.respond_to?(:path) && tempfile.respond_to?(:size)
        raise InvalidUpload if tempfile.size > MAX_SIZE

        tempfile.rewind
        Digest::SHA256.file(tempfile.path).hexdigest
      rescue InvalidUpload
        raise
      rescue StandardError => exception
        raise Unavailable, exception.class.name
      ensure
        tempfile&.rewind
      end

      def initialize(upload:, content_sha256:)
        @upload = upload
        @content_sha256 = content_sha256
      end

      def call
        tempfile = upload.tempfile
        tempfile.rewind
        blob = ActiveStorage::Blob.create_after_unfurling!(
          io: tempfile,
          filename: "profile-avatar",
          content_type: upload.content_type,
          identify: true
        )
        blob.upload_without_unfurling(tempfile)

        if CONTENT_TYPES.exclude?(blob.content_type)
          result = failure(error(:invalid_avatar, :unprocessable_entity))
        elsif !valid_image?(blob)
          result = failure(error(:invalid_avatar, :unprocessable_entity))
        else
          blob.variant(Core::UserProfile::THUMB_VARIANT).processed
          result = success(Result.new(blob: blob, content_sha256: content_sha256))
        end
        result
      rescue ActiveStorage::InvariableError
        result = failure(error(:invalid_avatar, :unprocessable_entity))
      rescue StandardError => exception
        Rails.logger.error("profile avatar preflight failed error_class=#{exception.class.name}")
        result = failure(error(:avatar_processing_unavailable, :service_unavailable))
      ensure
        purge_blob(blob) if blob && result&.failure?
      end

      private

      attr_reader :upload, :content_sha256

      def valid_image?(blob)
        blob.open do |file|
          ImageProcessing::Vips.valid_image?(file)
        end
      rescue LoadError, ActiveStorage::Error, IOError, SystemCallError => exception
        raise Unavailable, exception.class.name
      end

      def purge_blob(blob)
        blob.purge unless blob.attachments.exists?
      rescue StandardError => exception
        Rails.logger.error("profile avatar cleanup failed error_class=#{exception.class.name}")
      end

      def error(key, status)
        Core::BusinessError.new(I18n.t("user.errors.#{key}"), code: key.to_s, status: status)
      end
    end
  end
end
