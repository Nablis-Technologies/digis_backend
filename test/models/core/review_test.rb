require "test_helper"

class CoreReviewTest < ActiveSupport::TestCase
  test "defaults context and status when blank" do
    review = Core::Review.new(
      reviewable: core_roles(:user)
    )

    review.valid?

    assert_equal "default", review.context
    assert_equal "draft", review.status
  end
end
