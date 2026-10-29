# frozen_string_literal: true

module Messaging
  module Campaigns
    module ContactLists
      # Changes list metadata without changing a campaign snapshot.
      class Update < Core::BaseService
        def initialize(list:, actor:, attributes:, idempotency_key:)
          @list = list
          @actor = actor
          @attributes = attributes.to_h.symbolize_keys.slice(:name, :status)
          @idempotency_key = Core::IdempotencyKey.new(idempotency_key)
        end

        def call
          @list.update!(@attributes)
          success(@list)
        rescue ArgumentError => exception
          failure(Core::BusinessError.new(exception.message, code: "invalid_idempotency_key", status: :bad_request))
        rescue ActiveRecord::RecordInvalid => exception
          failure(Core::BusinessError.new(
            I18n.t("messaging.errors.contact_list_invalid"),
            code: "contact_list_invalid", status: :unprocessable_entity,
            errors: exception.record.errors.to_hash
          ))
        end
      end
    end
  end
end
