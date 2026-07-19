# frozen_string_literal: true

module Ticketing
  class ApplicationRecord < Core::ApplicationRecord
    self.abstract_class = true
  end
end
