# frozen_string_literal: true

module Messaging
  # Immutable contract for one transactional notification type. Recipient,
  # projection, and dedupe rules stay together so callers cannot introduce
  # arbitrary JSON or cross-user delivery through a database row.
  class NotificationTypeDefinition
    attr_reader :key, :category, :channels, :data_keys, :locale_scope

    def initialize(key:, category:, mandatory:, channels:, data_keys:, locale_scope:,
      recipient_resolver:, dedupe_resolver:, projector: nil)
      @key = key.to_s.freeze
      @category = category.to_s.freeze
      @mandatory = mandatory == true
      @channels = channels.map(&:to_s).freeze
      @data_keys = data_keys.map(&:to_s).freeze
      @locale_scope = locale_scope.to_s.freeze
      @recipient_resolver = recipient_resolver
      @dedupe_resolver = dedupe_resolver
      @projector = projector || ->(source:, payload:, **) { payload.slice(*@data_keys) }
      freeze
    end

    def mandatory?
      @mandatory
    end

    def recipients_for(source:, payload: {})
      Array(@recipient_resolver.call(source:, payload:)).compact.uniq { |recipient| recipient.id }
    end

    def recipient_for(source:, payload: {})
      recipients_for(source:, payload:).first
    end

    def dedupe_key_for(source:, recipient:, payload: {})
      key = @dedupe_resolver.call(source:, recipient:, payload:).to_s.strip
      raise ArgumentError, I18n.t("messaging.errors.dedupe_key_missing") if key.blank?

      key
    end

    def project(source:, payload: {})
      @projector.call(source:, payload:)
    end
  end
end
