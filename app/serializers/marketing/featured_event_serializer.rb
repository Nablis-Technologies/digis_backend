# frozen_string_literal: true

module Marketing
  class FeaturedEventSerializer < Events::Public::EventListSerializer
    attributes :placement_label

    def placement_label = "featured"
  end
end
