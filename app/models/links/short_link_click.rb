# frozen_string_literal: true

module Links
  # Privacy-limited asynchronous click detail. Redirect success never depends
  # on this row being written.
  class ShortLinkClick < Links::ApplicationRecord
    self.table_name = "links_short_link_clicks"

    belongs_to :short_link, class_name: "Links::ShortLink", inverse_of: :clicks

    validates :short_link, :clicked_at, presence: true
    validates :country, format: { with: /\A[A-Z]{2}\z/ }, allow_nil: true

    def self.ransackable_attributes(_auth_object = nil)
      %w[id short_link_id referrer device_type country clicked_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[short_link]
    end
  end
end
