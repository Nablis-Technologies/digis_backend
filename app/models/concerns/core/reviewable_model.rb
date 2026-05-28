module Core
  module ReviewableModel
    extend ActiveSupport::Concern

    included do
      has_many :reviews, as: :reviewable, class_name: "Core::Review", dependent: :destroy
    end

    def review_for(context = :default)
      reviews.with_context(context).recent_first
    end

    def current_review_for(context = :default)
      review_for(context).first
    end

    def current_status_for(context = :default)
      current_review_for(context)&.status || "draft"
    end

    def build_review_for(context = :default)
      reviews.build(context: context.to_s)
    end

    def draft?(context = :default)
      current_status_for(context) == "draft"
    end

    def pending?(context = :default)
      current_status_for(context) == "pending"
    end

    def approved?(context = :default)
      current_status_for(context) == "approved"
    end

    def rejected?(context = :default)
      current_status_for(context) == "rejected"
    end

    def modification_requested?(context = :default)
      current_status_for(context) == "modify"
    end

    def editable?(context = :default)
      draft?(context)
    end

    def submitted?(context = :default)
      !draft?(context)
    end
  end
end
