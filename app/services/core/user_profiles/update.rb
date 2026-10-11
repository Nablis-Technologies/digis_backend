# frozen_string_literal: true

module Core
  module UserProfiles
    class Update < Core::BaseService
      Result = Data.define(:user, :profile, :replayed)

      def initialize(user:, attributes:, idempotency_key:, request:)
        @user = user
        @attributes = attributes.to_h.symbolize_keys.slice(:first_name, :last_name, :avatar, :remove_avatar)
        @raw_idempotency_key = idempotency_key
        @request = request
      end

      def call
        candidate_blob = nil
        return failure(error(:user_not_found, :unauthorized)) unless user.is_a?(Core::User)

        key = Core::IdempotencyKey.new(raw_idempotency_key)
        upload = attributes[:avatar].presence
        remove_avatar = remove_avatar?
        return failure(error(:avatar_operation_conflict, :unprocessable_entity)) if upload && remove_avatar

        content_sha256 = AvatarUpload.fingerprint(upload)
        request_digest = request_digest_for(content_sha256:, remove_avatar:)
        audit_key = "core-user-profile-update-#{user.id}-#{key.digest}"
        replay = replay_result(user, audit_key:, request_digest:)
        return replay if replay

        if upload
          upload_result = AvatarUpload.call(upload:, content_sha256:)
          return failure(upload_result.error) if upload_result.failure?

          candidate_blob = upload_result.value.blob
        end

        persist_profile(key:, audit_key:, request_digest:, candidate_blob:, remove_avatar:)
      rescue ArgumentError
        failure(error(:invalid_idempotency_key, :bad_request))
      rescue AvatarUpload::InvalidUpload
        failure(error(:invalid_avatar, :unprocessable_entity))
      rescue AvatarUpload::Unavailable
        failure(error(:avatar_processing_unavailable, :service_unavailable))
      rescue ActiveRecord::RecordNotFound
        failure(error(:user_not_found, :not_found))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:profile_invalid, :unprocessable_entity, errors: exception.record.errors.to_hash))
      rescue Core::Audit::Record::ReplayConflict
        failure(error(:idempotency_conflict, :conflict))
      ensure
        purge_unattached_blob(candidate_blob)
      end

      private

      attr_reader :user, :attributes, :raw_idempotency_key, :request

      def persist_profile(key:, audit_key:, request_digest:, candidate_blob:, remove_avatar:)
        outcome = nil
        Core::User.transaction do
          locked_user = Core::User.lock.find(user.id)
          replay = replay_result(locked_user, audit_key:, request_digest:)
          if replay
            outcome = replay
            next
          end

          profile = Core::UserProfile.with_attached_avatar.find_by(user_id: locked_user.id)
          if profile.nil? && candidate_blob.nil? && remove_avatar && profile_attributes.empty?
            record_update!(
              actor: locked_user,
              auditable: locked_user,
              profile: nil,
              changed_fields: [],
              audit_key:,
              key:,
              request_digest:
            )
            outcome = success(Result.new(user: locked_user, profile: nil, replayed: false))
            next
          end

          profile ||= Core::UserProfile.new(user: locked_user)
          profile.assign_attributes(profile_attributes)
          profile.avatar = candidate_blob if candidate_blob
          profile.avatar = nil if remove_avatar
          profile.save!

          changed_fields = profile.previous_changes.keys & %w[first_name last_name]
          changed_fields << "avatar" if candidate_blob || remove_avatar
          record_update!(
            actor: locked_user,
            auditable: profile,
            profile: profile,
            changed_fields: changed_fields.uniq,
            audit_key:,
            key:,
            request_digest:
          )
          outcome = success(Result.new(user: locked_user, profile: profile, replayed: false))
        end
        outcome
      end

      def profile_attributes
        attributes.slice(:first_name, :last_name)
      end

      def remove_avatar?
        ActiveModel::Type::Boolean.new.cast(attributes[:remove_avatar])
      end

      def request_digest_for(content_sha256:, remove_avatar:)
        supplied_fields = %i[first_name last_name].each_with_object({}) do |name, result|
          result[name] = Core::UserProfile.normalize_name(attributes[name]) if attributes.key?(name)
        end
        payload = {
          user_id: user.id,
          supplied_fields: supplied_fields,
          avatar_content_sha256: content_sha256,
          remove_avatar: remove_avatar
        }
        Core::KeyedDigest.digest(
          namespace: "core/user-profile-update/request",
          value: ActiveSupport::JSON.encode(payload)
        )
      end

      def replay_result(requested_user, audit_key:, request_digest:)
        audit = Core::AuditLog.find_by(audit_key:)
        return unless audit

        metadata = audit.metadata.deep_stringify_keys
        return failure(error(:idempotency_conflict, :conflict)) unless metadata["request_digest"] == request_digest

        profile = if audit.auditable_type == Core::UserProfile.name
          Core::UserProfile.with_attached_avatar.find_by(id: audit.auditable_id)
        end
        return failure(error(:profile_update_failed, :unprocessable_entity)) if
          audit.auditable_type == Core::UserProfile.name && profile.nil?
        return failure(error(:idempotency_conflict, :conflict)) unless
          [ Core::UserProfile.name, Core::User.name ].include?(audit.auditable_type)
        return failure(error(:idempotency_conflict, :conflict)) if
          audit.auditable_type == Core::User.name && audit.auditable_id != requested_user.id

        success(Result.new(user: Core::User.find(requested_user.id), profile: profile, replayed: true))
      end

      def record_update!(actor:, auditable:, profile:, changed_fields:, audit_key:, key:, request_digest:)
        audit = Core::Audit::Record.call(
          audit_key:,
          action: "core.user.profile_updated",
          auditable_type: auditable.class.name,
          auditable_id: auditable.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          request_uuid: request.request_id,
          ip_address: request.remote_ip,
          user_agent: request.user_agent,
          metadata: {
            profile_id: profile&.id,
            changed_fields: changed_fields,
            idempotency_key_digest: key.digest,
            request_digest: request_digest
          }
        )
        raise audit.error if audit.failure?
      end

      def purge_unattached_blob(blob)
        return unless blob&.persisted? && !blob.attachments.exists?

        blob.purge
      rescue StandardError => exception
        Rails.logger.error("profile avatar cleanup failed error_class=#{exception.class.name}")
      end

      def error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("user.errors.#{key}"),
          code: key.to_s,
          status: status,
          errors: errors
        )
      end
    end
  end
end
