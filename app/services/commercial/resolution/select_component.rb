# frozen_string_literal: true

module Commercial
  module Resolution
    # Selects one component without a tie-breaker. A matching conflict at the
    # same layer and specificity is a configuration error, so this service
    # deliberately fails closed instead of choosing by database order or UUID.
    class SelectComponent < Core::BaseService
      Selection = Data.define(:component, :version, :assignment, :source, :precedence, :specificity)

      SCOPE_ATTRIBUTES = %i[
        event_product_id product_type sale_context provider payment_method sales_channel currency
      ].freeze

      def initialize(component_type:, context:, candidates: nil, components: nil)
        @component_type = component_type.to_s
        @context = context
        @candidates = normalize_candidates(candidates || components || [])
      end

      def call
        matching = @candidates.select { |candidate| matches?(candidate.component) }
        return failure(error("commercial_terms_unavailable")) if matching.empty?

        # A persisted component is unique by database ID; the object identity
        # fallback keeps direct, unsaved callers from hiding a real tie.
        matching = matching.uniq { |candidate| candidate.component.id || candidate.component.object_id }
        highest_precedence = matching.map(&:precedence).max
        matching = matching.select { |candidate| candidate.precedence == highest_precedence }
        highest_specificity = matching.map { |candidate| specificity(candidate.component) }.max
        winners = matching.select { |candidate| specificity(candidate.component) == highest_specificity }
        return failure(error("ambiguous_commercial_terms")) if winners.length > 1

        winner = winners.first
        success(
          Selection.new(
            component: winner.component,
            version: winner.version,
            assignment: winner.assignment,
            source: winner.source,
            precedence: winner.precedence,
            specificity: highest_specificity
          )
        )
      end

      private

      def normalize_candidates(candidates)
        candidates.map do |candidate|
          next candidate if candidate.is_a?(CandidateQuery::Candidate)

          CandidateQuery::Candidate.new(
            component: candidate,
            version: candidate.fee_schedule_version,
            assignment: nil,
            source: :platform_default,
            precedence: CandidateQuery::SOURCE_PRECEDENCE.fetch(:platform_default)
          )
        end
      end

      def matches?(component)
        component.component_type == @component_type && SCOPE_ATTRIBUTES.all? do |attribute|
          scope_matches?(component.public_send(attribute), @context.public_send(attribute))
        end
      end

      def scope_matches?(candidate_value, context_value)
        return true if candidate_value.blank?
        return false if context_value.blank?

        candidate_value.to_s == context_value.to_s
      end

      # The array order is contractual. Product identity dominates product
      # type, which dominates sale/provider/method/channel/currency context.
      def specificity(component)
        SCOPE_ATTRIBUTES.map do |attribute|
          component.public_send(attribute).present? ? 1 : 0
        end
      end

      def error(code)
        Core::BusinessError.new(
          I18n.t("commercial.resolution.errors.#{code}"),
          code:, status: :unprocessable_entity
        )
      end
    end
  end
end
