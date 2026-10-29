# frozen_string_literal: true

module Messaging
  module Campaigns
    module ContactLists
      # Creates one reusable contact list for an organization.
      class Create < Core::BaseService
        def initialize(organization:, actor:, name:, idempotency_key:)
          @organization = organization
          @actor = actor
          @name = name.to_s.strip
          @idempotency_key = Core::IdempotencyKey.new(idempotency_key)
        end

        def call
          return failure(error(:contact_list_name_required)) if @name.blank?
          return failure(error(:contact_list_limit_exceeded)) if list_limit_reached?

          list = CampaignContactList.find_or_initialize_by(organization: @organization, name: @name)
          list.created_by ||= @actor
          list.save!
          success(list)
        rescue ArgumentError => exception
          failure(Core::BusinessError.new(exception.message, code: "invalid_idempotency_key", status: :bad_request))
        rescue ActiveRecord::RecordInvalid => exception
          failure(error(:contact_list_invalid, errors: exception.record.errors.to_hash))
        end

        private

        def list_limit_reached?
          CampaignContactList.where(organization: @organization).count >= 50 &&
            !CampaignContactList.exists?(organization: @organization, name: @name)
        end

        def error(key, status: :unprocessable_entity, errors: nil)
          Core::BusinessError.new(I18n.t("messaging.errors.#{key}"), code: key.to_s, status:, errors:)
        end
      end
    end
  end
end
