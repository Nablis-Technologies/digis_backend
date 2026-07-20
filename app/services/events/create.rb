# frozen_string_literal: true

module Events
  # Creates a draft event owned by the given organization. The acting user is
  # recorded as creator. An accompanying settings row is built so every event
  # always has one (enforced by the one-settings-per-event unique index).
  class Create < Core::BaseService
    def initialize(organization:, actor:, attributes:, category_ids: [])
      @organization = organization
      @actor = actor
      @attributes = attributes.to_h.symbolize_keys
      @category_ids = Array(category_ids).map(&:to_s)
    end

    def call
      event = nil
      Events::Event.transaction do
        event = Events::Event.new(@attributes.merge(organization: @organization, created_by: @actor))
        return failure(invalid(event)) unless event.valid?

        event.save!
        event.create_event_setting!(config: {})
        event.record_audit!(
          "event.created",
          audited_changes: event.attributes,
          actor: @actor
        )

        attach_categories(event) if @category_ids.present?
      end
      success(event)
    rescue ActiveRecord::RecordInvalid => error
      failure invalid(error.record)
    end

    private

    def attach_categories(event)
      Events::ReplaceCategories.call(event:, category_ids: @category_ids, actor: @actor)
    end

    private

    def invalid(record)
      Core::BusinessError.new(
        I18n.t("events.create.errors.invalid_event"),
        code: "invalid_event",
        status: :unprocessable_entity,
        errors: record.errors.to_hash
      )
    end
  end
end
