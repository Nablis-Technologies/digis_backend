# frozen_string_literal: true

module Messaging
  # Returns the authenticated organization's derived per-channel balances.
  # The controller exposes the report service only; ledger arithmetic stays in
  # Messaging::CreditAccounts::BalanceReport.
  class CreditAccountsController < Messaging::ApplicationController
    def index
      organization = Organizations::Organization.find(params[:organization_id])
      authorize CreditAccount.new(organization:), :index?

      result = CreditAccounts::BalanceReport.call(organization:)
      render_service_result(result)
    end
  end
end
