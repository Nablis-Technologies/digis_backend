module Core
  module FollowableLookup
    extend ActiveSupport::Concern

    REGISTRY = {
      "venues" => Events::Venue,
      "artists" => Events::Artist,
      "organizations" => Organizations::Organization
    }.freeze

    private

    def followable
      @followable ||= find_followable!
    end

    def find_followable!
      type = params[:followable_type]
      klass = REGISTRY[type]
      raise ActiveRecord::RecordNotFound, I18n.t("core.errors.unsupported_followable_type", type:) unless klass

      klass.find(params[:followable_id])
    end
  end
end
