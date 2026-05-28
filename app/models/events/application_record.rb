module Events
  class ApplicationRecord < Core::ApplicationRecord
    self.abstract_class = true
  end
end
