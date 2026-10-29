# frozen_string_literal: true

module Messaging
  # Lists the effective organization/global rate definitions visible to an
  # organizer. Lifecycle changes belong to the admin controller and commands.
  class CreditRatesController < Messaging::ApplicationController
    def index
      organization = Organizations::Organization.find(params[:organization_id])
      authorize CreditRateVersion.new(organization:), :index?
      @clazz = CreditRateVersion
      rates = CreditRateVersionPolicy::Scope.new(current_user, CreditRateVersion.all).resolve
        .where(organization_id: [ organization.id, nil ])
        .includes(:organization)
      rates = filter_records(rates)
      rates = apply_ordering(rates)
      total_count = rates.count if paginated_request?
      rates = paginated_request? ? apply_pagination(rates) : rates.limit(default_per_page)
      render_success(
        data: rates,
        serializer_options: { serializer: CreditRateVersionSerializer },
        pagination: paginated_request? ? pagination_metadata(total_count) : nil
      )
    end

    private

    def allowed_order_columns
      %w[id channel version currency country_code effective_from effective_until status created_at]
    end

    def serializer_profile
      { index: { fields: CreditRateVersionPolicy::FIELDS, include: [] } }
    end
  end
end
