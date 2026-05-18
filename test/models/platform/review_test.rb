require "test_helper"

class PlatformReviewTest < ActiveSupport::TestCase
  test "defaults context and status when blank" do
    review = Platform::Review.new(
      reviewable: platform_roles(:user)
    )

    review.valid?

    assert_equal "default", review.context
    assert_equal "draft", review.status
  end
end
