# frozen_string_literal: true

module Messaging
  # Shared authenticated API boundary for recipient-owned notification data.
  # Pagination and filtering are opt-in concerns so each controller must still
  # declare its allowed fields, associations, and ordering explicitly.
  class ApplicationController < Core::ApplicationController
    include Core::Pagination
    include Core::Filterable
  end
end
