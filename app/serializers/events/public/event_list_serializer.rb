# frozen_string_literal: true

module Events
  module Public
    class EventListSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer

      attributes :id, :slug, :title, :description, :visibility,
                 :timezone, :currency, :published_at, :price_from_minor,
                 :price_from_currency, :event_lifecycle, :ticket_availability,
                 :next_event_date, :is_recurring

      has_many :categories, serializer: Events::Public::CategorySerializer
      has_many :event_media, serializer: Events::Public::EventMediaSerializer
      has_many :event_organizations, serializer: Events::Public::EventOrganizationSerializer
      has_one :event_setting, serializer: Events::Public::EventSettingSerializer
      has_one :organization, serializer: Events::Public::OrganizationSummarySerializer

      def price_from_minor
        event_status[:price_from_minor]
      end

      def price_from_currency
        event_status[:price_from_currency] || object.currency
      end

      def event_lifecycle
        event_status.fetch(:event_lifecycle, "unscheduled")
      end

      def ticket_availability
        event_status.fetch(:ticket_availability, "no_public_tickets")
      end

      def next_event_date
        date = instance_options.fetch(:event_date_previews, {}).fetch(object.id, []).first
        Events::Public::EventDateSerializer.new(date).attributes if date
      end

      def is_recurring
        instance_options.fetch(:recurring_event_ids, []).include?(object.id)
      end

      private

      def event_status
        instance_options.fetch(:event_statuses, {}).fetch(object.id, {})
      end
    end
  end
end
