# frozen_string_literal: true

module Messaging
  # Keeps Messaging tables and connection behavior behind the module boundary.
  class ApplicationRecord < Core::ApplicationRecord
    self.abstract_class = true
  end
end
