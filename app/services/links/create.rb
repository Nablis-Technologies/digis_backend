# frozen_string_literal: true

module Links
  # Creates a feature-gated branded link after target authorization and target
  # validation. Canonical uniqueness is enforced again by PostgreSQL.
  class Create < Core::BaseService
    def initialize(creator:, slug:, target_type: nil, target_id: nil, custom_url: nil,
      canonical: false, expires_at: nil, max_clicks: nil, utm_source: nil,
      utm_medium: nil, utm_campaign: nil)
      @creator = creator
      @attributes = {
        slug:, target_type:, target_id:, custom_url:, creator_id: creator&.id,
        canonical:, expires_at:, max_clicks:, click_count: 0,
        utm_source:, utm_medium:, utm_campaign:
      }
    end

    def call
      return failure(error(:short_links_disabled, :not_found)) unless enabled?

      link = Links::ShortLink.new(@attributes)
      return failure(error(:unauthorized, :forbidden)) unless Links::ShortLinkPolicy.new(@creator, link).create?
      return failure(error(:target_not_found, :unprocessable_entity)) if link.internal_target? && target_location.nil?

      link.save!
      success(link)
    rescue ActiveRecord::RecordInvalid => exception
      failure(error(:invalid_link, :unprocessable_entity, errors: exception.record.errors.to_hash))
    rescue ActiveRecord::RecordNotUnique
      failure(error(:slug_taken, :conflict))
    end

    private

    def enabled?
      Rails.application.config.x.short_links.enabled
    end

    def target_location
      @target_location ||= TargetResolver.call(@attributes[:target_type], @attributes[:target_id])
    rescue Core::Error
      nil
    end

    def error(key, status, errors: nil)
      Core::BusinessError.new(
        I18n.t("links.errors.#{key}"),
        code: key,
        status:,
        errors:
      )
    end
  end
end
