# frozen_string_literal: true

module Events
  module Organizer
    # Organizer event projection. It provides one bounded display graph while
    # keeping mutation responses on the existing generic event serializer.
    class EventSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer

      attributes :id, :slug, :title, :description, :status, :visibility,
                 :timezone, :currency, :version, :published_at, :cancelled_at,
                 :created_at, :updated_at, :organization_id, :organization,
                 :categories, :event_dates, :event_media

      attribute :event_setting, if: :show_projection? do
        Events::Organizer::EventSettingSerializer.new(object.event_setting).attributes
      end

      def organization
        Events::Public::OrganizationSummarySerializer.new(object.organization).attributes
      end

      def categories
        object.categories.map do |category|
          Events::Public::CategorySerializer.new(category).attributes
        end
      end

      def event_dates
        object.event_dates.sort_by { |event_date| [ event_date.starts_at, event_date.id ] }.map do |event_date|
          Events::Organizer::EventDateSerializer.new(event_date).attributes
        end
      end

      def event_media
        media = object.event_media.sort_by { |event_media| [ event_media.position, event_media.id ] }
        media = media.select { |event_media| event_media.type == "cover" }.first(1) if list_projection?
        media.map { |event_media| Events::Public::EventMediaSerializer.new(event_media).attributes }
      end

      def show_projection?
        return false unless instance_options[:projection].to_s == "show"

        setting_association = object.association(:event_setting)
        setting_association.loaded? && setting_association.target.present?
      end

      private

      def list_projection?
        instance_options[:projection].to_s == "index"
      end
    end
  end
end
