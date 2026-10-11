# frozen_string_literal: true

require "digest"

module Core
  module UserProfiles
    class AvatarUpload < Core::BaseService
      MAX_SIZE = 5.megabytes
      MAX_DIMENSION = 6_000
      MAX_PIXELS = 12_000_000
      CONTENT_TYPES = %w[image/jpeg image/png image/webp].freeze
      PROCESSING_LOCK = Mutex.new

      Result = Data.define(:blob, :content_sha256)

      class InvalidUpload < StandardError; end
      class Unavailable < StandardError; end

      def self.with_processing_lock(&block)
        PROCESSING_LOCK.synchronize(&block)
      end

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
        blob = ActiveStorage::Blob.build_after_unfurling(
          io: tempfile,
          filename: "profile-avatar",
          content_type: upload.content_type,
          identify: true
        )
        return failure(error(:invalid_avatar, :unprocessable_entity)) if CONTENT_TYPES.exclude?(blob.content_type)
        return failure(error(:invalid_avatar, :unprocessable_entity)) unless self.class.with_processing_lock { valid_image?(tempfile) }

        tempfile.rewind
        blob.save!
        blob.upload_without_unfurling(tempfile)
        self.class.with_processing_lock { blob.variant(Core::UserProfile::THUMB_VARIANT).processed }
        success(Result.new(blob: blob, content_sha256: content_sha256))
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

      def valid_image?(file)
        file.rewind
        image = ::Vips::Image.new_from_file(file.path, access: :sequential)
        return false unless image_dimensions_allowed?(image.width, image.height)

        image.avg
        true
      rescue ::Vips::Error
        false
      rescue LoadError, IOError, SystemCallError => exception
        raise Unavailable, exception.class.name
      ensure
        file.rewind if file.respond_to?(:rewind)
      end

      def image_dimensions_allowed?(width, height)
        width.positive? && height.positive? &&
          width <= MAX_DIMENSION && height <= MAX_DIMENSION &&
          width * height <= MAX_PIXELS
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
