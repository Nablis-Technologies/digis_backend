# frozen_string_literal: true

module Events
  # Replaces an event's full category set, enforcing the maximum cardinality
  # inside a single locked transaction so concurrent callers cannot observe
  # (or commit) more than MAX_CATEGORIES rows.
  class ReplaceCategories < Core::BaseService
    MAX_CATEGORIES = Events::Event::MAX_CATEGORIES

    def initialize(event:, category_ids:, actor:)
      @event = event
      @category_ids = Array(category_ids).map(&:to_s)
      @actor = actor
    end

    def call
      return too_many_error if @category_ids.size > MAX_CATEGORIES

      result = nil
      Events::Event.transaction do
        @event.lock!

        @event.event_categories.destroy_all
        categories = Events::Category.where(id: @category_ids).to_a
        categories.each do |category|
          @event.event_categories.create!(category:)
        end

        @event.record_audit!(
          "event.categories_replaced",
          audited_changes: { category_ids: @category_ids },
          actor: @actor
        )

        result = success(@event)
      end
      result
    rescue ActiveRecord::RecordInvalid => error
      failure Core::BusinessError.new(
        I18n.t("events.replace_categories.errors.invalid_category"),
        code: "invalid_category",
        status: :unprocessable_entity,
        errors: error.record.errors.to_hash
      )
    end

    private

    def too_many_error
      failure Core::BusinessError.new(
        I18n.t("events.replace_categories.errors.too_many_categories",
               max: MAX_CATEGORIES),
        code: "too_many_categories",
        status: :unprocessable_entity
      )
    end
  end
end
