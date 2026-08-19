# frozen_string_literal: true

module Links
  # Owns system-generated canonical links separately from user-created links.
  # Only the enable-later backfill job calls this command, and it accepts
  # allowlisted persisted targets rather than exposing an authorization bypass
  # on the normal link-creation service.
  class BackfillCanonical < Core::BaseService
    ResultValue = Data.define(:status, :collisions)
    TARGETS = {
      "event" => Events::Event,
      "ticket" => Ticketing::Ticket,
      "organization" => Organizations::Organization
    }.freeze

    def initialize(target_type:, target:, canonical_ids:)
      @target_type = target_type.to_s
      @target = target
      @canonical_ids = canonical_ids
    end

    def call
      return success(ResultValue.new(:preserved, 0)) if canonical_exists_in_batch?
      return failure(error(:target_not_found, :unprocessable_entity)) unless valid_target?

      candidates.each_with_index do |slug, index|
        link = ShortLink.new(
          slug:, target_type: @target_type, target_id: @target.id,
          canonical: true, click_count: 0
        )
        link.save!
        @canonical_ids.add(@target.id)
        return success(ResultValue.new(:created, index))
      rescue ActiveRecord::RecordNotUnique
        return success(ResultValue.new(:preserved, index)) if canonical_exists_in_database?
      rescue ActiveRecord::RecordInvalid => exception
        return failure(error(:invalid_link, :unprocessable_entity, errors: exception.record.errors.to_hash))
      end

      failure(error(:slug_taken, :conflict))
    end

    private

    def valid_target?
      target_class = TARGETS[@target_type]
      target_class && @target.is_a?(target_class) && @target.persisted?
    end

    def canonical_exists_in_batch?
      @canonical_ids.include?(@target.id)
    end

    def canonical_exists_in_database?
      exists = ShortLink.exists?(canonical: true, target_type: @target_type, target_id: @target.id)
      @canonical_ids.add(@target.id) if exists
      exists
    end

    def candidates
      base = normalized_base_slug
      slugs = [ base ] unless ShortLink::RESERVED_SLUGS.include?(base)
      token = @target.id.to_s.delete("-")
      slugs ||= []
      slugs << suffixed_slug(base, token.first(8))
      slugs << suffixed_slug(base, token.first(16))
      slugs.compact.uniq
    end

    def normalized_base_slug
      base = if @target_type == "ticket"
        "ticket-#{@target.id}"
      else
        @target.slug
      end

      normalized = base.to_s.downcase.strip.gsub(/[^a-z0-9_-]+/, "-")
      normalized = normalized.gsub(/\A[-_]+|[-_]+\z/, "")
      normalized.presence || "#{@target_type}-#{@target.id}"
    end

    def suffixed_slug(base, suffix)
      available = ShortLink::MAX_SLUG_LENGTH - suffix.length - 1
      "#{base.first(available).sub(/[-_]\z/, "")}-#{suffix}"
    end

    def error(key, status, errors: nil)
      Core::BusinessError.new(
        I18n.t("links.errors.#{key}"), code: key, status:, errors:
      )
    end
  end
end
