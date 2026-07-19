# frozen_string_literal: true

module Catalog
  class ApplicationRecord < Core::ApplicationRecord
    self.abstract_class = true
  end
end
