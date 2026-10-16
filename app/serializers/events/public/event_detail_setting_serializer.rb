# frozen_string_literal: true

module Events
  module Public
    # Adds the narrowly public age restriction to event detail without changing
    # the existing event-card settings projection.
    class EventDetailSettingSerializer < EventSettingSerializer
      def config
        super.tap do |settings|
          age_restriction = object.safe_age_restriction
          settings["age_restriction"] = age_restriction if age_restriction.present?
        end
      end
    end
  end
end
