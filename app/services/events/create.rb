# frozen_string_literal: true

module Events
  # Creates a draft event owned by the given organization. The acting user is
  # recorded as creator. An accompanying settings row is built so every event
  # always has one (enforced by the one-settings-per-event unique index).
  class Create < Core::BaseService
    def initialize(organization:, actor:, attributes:, category_ids: [], age_restriction_attributes: {})
      @organization = organization
      @actor = actor
      @attributes = attributes.to_h.symbolize_keys
      @category_ids = Array(category_ids).map(&:to_s)
      @age_restriction_attributes = age_restriction_attributes.to_h.symbolize_keys
    end

    def call
      return failure(not_authorized) unless Events::AuthorizationResolver.organization_admin?(@actor, @organization)

      outcome = nil
      Events::Event.transaction do
        event = Events::Event.new(@attributes.merge(organization: @organization, created_by: @actor))
        return failure(invalid(event)) unless event.valid?

        event.save!
        event_setting = event.build_event_setting(config: {})
        if @age_restriction_attributes.key?(:age_restriction)
          event_setting.age_restriction = @age_restriction_attributes[:age_restriction]
        end
        unless event_setting.save
          outcome = failure(invalid(event_setting))
          raise ActiveRecord::Rollback
        end

        event.record_audit!(
          "event.created",
          audited_changes: event.attributes.merge(
            "event_setting" => { "age_restriction" => event_setting.age_restriction }
          ),
          actor: @actor
        )

        if @category_ids.present?
          category_result = attach_categories(event)
          unless category_result.success?
            outcome = category_result
            raise ActiveRecord::Rollback
          end
        end

        outcome = success(event)
      end
      outcome
    rescue ActiveRecord::RecordInvalid => error
      failure invalid(error.record)
    end

    private

    def attach_categories(event)
      Events::ReplaceCategories.call(event:, category_ids: @category_ids, actor: @actor)
    end

    def not_authorized
      Core::BusinessError.new(
        I18n.t("events.create.errors.not_authorized"),
        code: "not_authorized",
        status: :forbidden
      )
    end

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
