# frozen_string_literal: true

module Finance
  class ApplicationRecord < Core::ApplicationRecord
    self.abstract_class = true
  end
end
