# frozen_string_literal: true

module Marketing
  class ReconcileFeaturedPlacementsJob < ApplicationJob
    queue_as :maintenance

    def perform(limit = Marketing::FeaturedPlacements::Reconcile::DEFAULT_LIMIT)
      result = Marketing::FeaturedPlacements::Reconcile.call(limit:)
      raise result.error if result.failure?
    end
  end
end
