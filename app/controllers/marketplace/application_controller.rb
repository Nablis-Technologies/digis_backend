# frozen_string_literal: true

module Marketplace
  # Shared authenticated boundary for marketplace APIs. Resource controllers
  # add only their domain-specific commands and visibility projections here.
  class ApplicationController < Core::ApplicationController
  end
end
