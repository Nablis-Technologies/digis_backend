# frozen_string_literal: true

module Events
  module Public
    class EventListSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer

      attributes :id, :slug, :title, :description, :visibility,
                 :timezone, :currency, :published_at, :price_from_minor

      has_many :categories, serializer: Events::Public::CategorySerializer
      has_many :event_dates, serializer: Events::Public::EventDateSerializer
      has_many :event_media, serializer: Events::Public::EventMediaSerializer
      has_many :event_organizations, serializer: Events::Public::EventOrganizationSerializer
      has_one :event_setting, serializer: Events::Public::EventSettingSerializer
      has_one :organization, serializer: Events::Public::OrganizationSummarySerializer

      def price_from_minor
        object.event_products
          .select { |product| product.status == "active" && product.ticket? }
          .flat_map { |product| product.prices.select { |price| active_price?(price) } }
          .map(&:amount_minor)
          .min
      end

      private

      def active_price?(price)
        price.currency == object.currency && Catalog::Public::PriceWindow.active?(price, at: evaluation_time)
      end

      def evaluation_time = instance_options.fetch(:at, Time.current)
    end
  end
end
