# frozen_string_literal: true

module Links
  # Public branded redirect. It is host-constrained in routes, skips platform
  # authentication, and never treats a slug as ticket authorization material.
  class RedirectsController < Links::ApplicationController
    skip_before_action :authenticate_user
    skip_authorization

    def show
      result = Links::Resolve.call(slug: params[:slug], now: Time.current)
      return redirect_with_analytics(result.value) if result.success?
      return redirect_to_normal_route if result.error.code == "short_links_disabled"

      render_error(result.error, status: result.error.status, code: result.error.code)
    end

    private

    def redirect_with_analytics(resolution)
      Links::RecordClickJob.perform_later(resolution.short_link_id)
      redirect_to resolution.location, allow_other_host: resolution.location.start_with?("http")
    end

    def redirect_to_normal_route
      link = Links::ShortLink.by_slug(params[:slug]).first
      return render_error(Links::Resolve.call(slug: params[:slug], now: Time.current).error, status: :not_found) unless link&.internal_target?

      redirect_to Links::TargetResolver.call(link.target_type, link.target_id)
    rescue Core::Error, ActiveRecord::RecordNotFound
      render_error(Links::Resolve.call(slug: params[:slug], now: Time.current).error, status: :not_found)
    end
  end
end
