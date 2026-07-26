module Public
  class ApplicationController < ::ApplicationController
    include Core::JsonResponse
    include Core::Authenticatable
    include Core::Pagination
    include Core::RescuableErrors

    private

    def policy_for_data(data)
      nil
    end
  end
end
