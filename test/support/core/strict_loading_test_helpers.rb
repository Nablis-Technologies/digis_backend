# frozen_string_literal: true

module Core
  module StrictLoadingTestHelpers
    def with_strict_active_record_loading
      previous = ActiveRecord::Base.strict_loading_by_default
      ActiveRecord::Base.strict_loading_by_default = true
      yield
    ensure
      ActiveRecord::Base.strict_loading_by_default = previous
    end
  end
end
