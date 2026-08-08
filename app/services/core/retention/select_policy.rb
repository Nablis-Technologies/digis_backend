# frozen_string_literal: true

module Core
  module Retention
    # Resolves the policy in force for a data category at a point in time.
    # Jurisdiction-specific policies take precedence over the default policy;
    # selecting the newest version preserves the policy evidence used later.
    class SelectPolicy < Core::BaseService
      def initialize(category:, jurisdiction_code: nil, at: Time.current)
        @category = category
        @jurisdiction_code = jurisdiction_code.to_s.strip.upcase.presence
        @at = at
      end

      def call
        # NULL sorts last here so a matching jurisdiction wins before version
        # ordering chooses the newest policy within the applicable scope.
        policy = scoped_policies
          .order(Arel.sql("(jurisdiction_code IS NULL) ASC"), version: :desc)
          .first
        return failure(policy_not_found) unless policy

        success(policy)
      end

      private

      attr_reader :category, :jurisdiction_code, :at

      def scoped_policies
        scope = DataRetentionPolicy.active.where(category:).where("effective_at <= ?", at)
        scope = if jurisdiction_code
          scope.where(jurisdiction_code: [ jurisdiction_code, nil ])
        else
          scope.where(jurisdiction_code: nil)
        end

        scope
      end

      def policy_not_found
        Core::BusinessError.new(
          I18n.t("core.retention.errors.policy_not_found"),
          code: "retention_policy_not_found",
          status: :unprocessable_entity
        )
      end
    end
  end
end
