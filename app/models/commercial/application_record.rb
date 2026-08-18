# frozen_string_literal: true

module Commercial
  class ApplicationRecord < Core::ApplicationRecord
    self.abstract_class = true
  end
end
