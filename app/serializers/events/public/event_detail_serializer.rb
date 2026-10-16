# frozen_string_literal: true

module Events
  module Public
    class EventDetailSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer

      attributes :id, :slug, :title, :description, :visibility,
                 :timezone, :currency, :published_at, :created_at,
                 :is_recurring, :event_dates_preview, :event_dates_url

      has_many :categories, serializer: Events::Public::CategorySerializer
      has_many :event_media, serializer: Events::Public::EventMediaSerializer
      has_many :event_organizations, serializer: Events::Public::EventOrganizationSerializer
      has_many :event_participants, serializer: Events::Public::EventParticipantSerializer do
        object.event_participants.sort_by { |participant| [ participant.display_order, participant.id ] }
      end
      has_one :event_setting, serializer: Events::Public::EventSettingSerializer
      has_one :organization, serializer: Events::Public::OrganizationSummarySerializer

      def is_recurring
        instance_options.fetch(:recurring_event_ids, []).include?(object.id)
      end

      def event_dates_preview
        instance_options.fetch(:event_date_previews, {}).fetch(object.id, []).map do |date|
          Events::Public::EventDateSerializer.new(date).attributes
        end
      end

      def event_dates_url
        "/public/events/#{object.slug}/dates"
      end
    end
  end
end
