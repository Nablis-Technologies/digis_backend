# frozen_string_literal: true

module Links
  # Resolves one branded link and atomically consumes its optional click cap.
  # Analytics are deliberately enqueued by the redirect controller only after
  # this decision succeeds.
  class Resolve < Core::BaseService
    Resolution = Data.define(:location, :short_link_id)

    def initialize(slug:, now: Time.current)
      @slug = slug.to_s.downcase
      @now = now
    end

    def call
      return failure(error(:short_links_disabled, :not_found)) unless enabled?

      link = Links::ShortLink.by_slug(@slug).first!
      return failure(error(:short_link_expired, :gone)) if link.expires_at.present? && link.expires_at <= @now

      location = link.internal_target? ? TargetResolver.call(link.target_type, link.target_id) : link.custom_url
      affected = Links::ShortLink.where(id: link.id)
        .where("max_clicks IS NULL OR click_count < max_clicks")
        .update_all("click_count = click_count + 1, updated_at = NOW()")
      return failure(error(:short_link_click_limit_reached, :gone)) unless affected == 1

      success(Resolution.new(location:, short_link_id: link.id))
    rescue ActiveRecord::RecordNotFound
      failure(error(:short_link_not_found, :not_found))
    rescue Core::Error => exception
      failure(error(:short_link_not_found, :not_found)) if exception.message == I18n.t("links.errors.target_not_found")
      failure(exception)
    end

    private

    def enabled?
      Rails.application.config.x.short_links.enabled
    end

    def error(key, status)
      Core::BusinessError.new(I18n.t("links.errors.#{key}"), code: key, status:)
    end
  end
end
