# frozen_string_literal: true

module Orders
  class ApplicationRecord < Core::ApplicationRecord
    self.abstract_class = true
  end
end
