# frozen_string_literal: true

module Catalog
  # Authorizes add-on reports against the event catalogue boundary. Report
  # rows are read models, so the event itself is the policy record and no
  # financial or credential model is exposed to Pundit serialization.
  class AddOnReportPolicy < Core::ApplicationPolicy
    FIELDS = %i[
      product_id type name quantity gross_minor refunded_minor net_minor currency settlement_currency
    ].freeze

    def index?
      Events::AuthorizationResolver.can_manage_catalog?(user, record)
    end

    VISIBILITY = {
      index: {
        default: { fields: FIELDS, include: [] },
        admin: { fields: FIELDS, include: [] }
      }
    }.freeze
  end
end
