Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  scope module: :core do
    post "auth/login", to: "auth#login"
    post "auth/signup/request_otp", to: "auth#signup_request_otp"
    post "auth/signup", to: "auth#signup"
    post "auth/refresh", to: "auth#refresh"
    post "auth/logout", to: "auth#logout"
    post "auth/reauthenticate", to: "auth#reauthenticate"
    get "auth/me", to: "auth#me"
    post "auth/phone_verifications", to: "phone_verifications#create"
  end

  resources :notifications, only: %i[index show], controller: "messaging/notifications" do
    post :read, on: :member
  end
  resource :notification_preferences, only: %i[show update],
    controller: "messaging/notification_preferences"

  scope "organizations/:organization_id/messaging", module: :messaging do
    resources :credits, only: :index, controller: "credit_accounts"
    resources :credit_ledger, only: :index, controller: "credit_ledger"
    resources :credit_rates, only: :index
    resources :credit_estimates, only: :create
    resources :credit_top_ups, only: %i[create show]
  end

  scope "organizations/:organization_id", module: :messaging do
    resources :campaigns, only: %i[index show create update] do
    post :estimate, on: :member
    post :attest, on: :member
    post :launch, on: :member
    post :pause, on: :member
    post :resume, on: :member
    post :cancel, on: :member
      post :abort, on: :member
      get :analytics, on: :member
    end
    resources :campaign_contact_lists, only: %i[index show create update destroy] do
      post :import, on: :member
      post :append, on: :member
      post :replace, on: :member
      resources :entries, controller: "campaign_contact_list_entries", only: %i[create destroy]
    end
    resources :campaign_templates, only: %i[index show create update]
    get "campaign_contact_lists/:id/imports/:import_id", to: "campaign_contact_list_imports#show"
    get "campaign_contact_lists/:id/imports/:import_id/report", to: "campaign_contact_list_imports#report"
  end

  post "messaging/webhooks/:provider/inbound", to: "messaging/campaign_webhooks#create"
  get "messaging/unsubscribe/:token", to: "messaging/campaign_unsubscribes#show"
  post "messaging/unsubscribe/:token", to: "messaging/campaign_unsubscribes#create"

  namespace :admin do
    namespace :messaging do
      resources :credit_rates, only: %i[index show create] do
        post :activate, on: :member
        post :retire, on: :member
      end
      resources :campaigns, only: %i[index show]
      resources :campaign_templates, only: %i[index show create update]
      resources :campaign_volume_policies, only: %i[index show update]
    end
    post "organizations/:organization_id/messaging/credit_adjustments",
      to: "messaging/credit_adjustments#create"
  end

  scope ":followable_type", constraints: { followable_type: %r{venues|artists|organizations} } do
    scope ":followable_id" do
      post   "follow",    to: "core/follows#create",    as: :follow
      delete "follow",    to: "core/follows#destroy"
      get    "followers", to: "core/followers#index",   as: :followers
    end
  end

  scope module: :events do
    post "events/staff_invitations/claim", to: "staff_invitations#claim"
    post "events/staff_invitations/preview", to: "staff_invitations#preview"

    resources :categories, only: %i[index show]
    resources :venues, only: %i[index show]
    resources :artists, only: %i[index show]

    resources :events, only: %i[index show create update] do
      post :publish, on: :member
      resources :event_organizations, only: %i[index show create update destroy] do
        post :revoke, on: :member
        post :activate, on: :member
      end
      resources :event_staff_assignments, only: %i[index show] do
        post :suspend, on: :member
        post :revoke, on: :member
        post :activate, on: :member
        post :change_role, on: :member
      end
      resources :staff_invitations, only: %i[index create] do
        post :resend, on: :member
        post :revoke, on: :member
      end
      get :staff_roster, on: :member, to: "staff_rosters#show"
      resources :event_dates, only: %i[index show create update destroy]
      resources :event_participants, only: %i[index show create update destroy]
      resources :access_zones, only: %i[index show create update destroy]
      resource :recurrence_rule, only: %i[show create update destroy] do
        post :activate, on: :member
        post :deactivate, on: :member
      end
      resources :event_schedule_changes, only: %i[create]
      resources :event_cancellations, only: %i[create]
      resources :event_media, only: %i[index show create update destroy] do
        post :reorder, on: :collection
      end
      resources :event_video_links, only: %i[index show create update destroy]
      resources :consent_documents, only: %i[index show create update destroy] do
        post :publish, on: :member
        post :activate, on: :member
        post :deactivate, on: :member
      end
    end
    resources :public_events, only: :index, path: "public/events"
    get "public/events/:slug", to: "public_events#public_show", as: :public_event
  end

  get "public/events/:event_slug/products", to: "catalog/public_products#index"
  get "public/events/:event_slug/ticket_types/:ticket_type_id/consent_requirements",
      to: "ticketing/public_consent_requirements#index"
  get "public/events/:event_slug/ticket_types/:ticket_type_id/registration_schema",
      to: "ticketing/public_registration_schemas#show"
  post "public/events/:event_slug/admission_selections/request_otp",
       to: "orders/admission_selections#request_otp"
  post "public/events/:event_slug/admission_selections",
       to: "orders/admission_selections#create"
  post "public/events/:event_slug/admission_offers/:event_product_id/waitlist/request_otp",
       to: "ticketing/public_waitlists#request_otp"
  post "public/events/:event_slug/admission_offers/:event_product_id/waitlist",
       to: "ticketing/public_waitlists#create"
  post "guest/ticket_types/:ticket_type_id/registrations",
       to: "ticketing/guest_registrations#create"

  get "events/:event_id/add_on_reports", to: "catalog/event_add_on_reports#index",
      as: :event_add_on_reports

  scope path: :catalog, module: :catalog do
    resources :product_prices, only: %i[index show create]
    resources :product_quotes, only: %i[create]
    resources :product_inventories, only: %i[index show]
    resources :promotions, only: %i[index show create update destroy] do
      post :publish, on: :member
      post :disable, on: :member
      post :quote, on: :member
    end
    resources :promotion_codes, only: %i[index show create] do
      post :reveal, on: :member
    end
  end

  resources :events, only: [] do
    scope module: :catalog do
      resources :event_products, only: %i[index show create update destroy] do
        post :activate, on: :member
        post :deactivate, on: :member
        patch :update_inventory_configuration, on: :member
        resources :product_accesses, only: %i[index] do
          post :replace, on: :collection
          resources :product_access_zones, only: %i[index] do
            post :replace, on: :collection
          end
        end
        resources :product_date_allocations, only: %i[index] do
          post :replace, on: :collection
        end
      end
    end
  end

  resources :events, only: [] do
    post :order_quotes, to: "orders/order_quotes#create"
    resources :orders, only: :create, controller: "orders/orders"
  end

  post "guest/events/:event_id/order_quotes", to: "orders/guest_order_quotes#create"
  post "guest/events/:event_id/orders", to: "orders/guest_orders#create"
  post "guest/orders", to: "orders/guest_orders#create"
  post "guest/orders/:order_id/payment_attempts", to: "orders/guest_payment_attempts#create"
  post "guest/payments/:payment_id/refresh", to: "orders/guest_payment_refresh#create"

  get "public/tickets/:ticket_id", to: "ticketing/public_ticket_views#show"
  post "public/gift_purchases/:id/resolve", to: "orders/public_gift_purchases#resolve"
  post "public/gift_purchases/:id/claim", to: "orders/public_gift_purchases#claim"
  get "public/ticket_transfers/:id", to: "ticketing/public_ticket_transfers#show"
  post "public/ticket_transfers/:id/request_otp", to: "ticketing/public_ticket_transfers#request_otp"
  post "public/ticket_transfers/:id/accept_guest", to: "ticketing/public_ticket_transfers#accept_guest"
  post "public/ticket_views/:token/request_otp", to: "core/phone_verifications#create"
  post "phone_verifications/:id/verify", to: "core/phone_verifications#verify"
  post "registrations/:id/claim_guest", to: "ticketing/guest_registrations#claim_guest"

  # Finance owns completion because it triggers the payout-maturity boundary;
  # the URL remains event-scoped for organizer operations.
  post "events/:event_id/complete", to: "finance/event_completions#complete"

  resources :orders, only: [] do
    resources :payment_attempts, only: :create, controller: "orders/payment_attempts"
    resources :gift_purchases, only: :index, controller: "orders/gift_purchases" do
      post :resend, on: :member
    end
    post :restart, on: :member, controller: "orders/orders"
  end

  post "payments/:provider/webhook", to: "orders/payment_webhooks#create"
  get "payments/:provider/callback", to: "orders/payment_callbacks#show"
  post "payments/:payment_id/refresh", to: "orders/payment_refresh#create"

  resources :events, only: [] do
    resources :registration_forms, controller: "ticketing/registration_forms", only: %i[index show create update destroy] do
      resources :versions, controller: "ticketing/registration_form_versions", only: %i[index show create] do
        post :publish, on: :member
      end
    end
  end

  resources :events, only: [] do
    resources :attendee_exports, controller: "ticketing/attendee_exports", only: %i[create]
  end

  resources :attendee_exports, controller: "ticketing/attendee_exports", only: %i[show] do
    post :download_authorizations, on: :member
  end

  resources :registration_answers, only: %i[show], controller: "ticketing/registration_answers" do
    post :revise, on: :member
  end

  resources :registrations, only: [] do
    resources :consents, only: :index, controller: "ticketing/registration_consents" do
      post :accept, on: :member
    end
    resource :purchase_limit_override, only: :create, controller: "ticketing/purchase_limit_overrides"
  end

  resources :registration_consents, only: [] do
    resource :withdrawal, only: :create, controller: "ticketing/registration_consent_withdrawals"
  end

  resources :ticket_types, only: [] do
    resources :registrations, only: :create, controller: "ticketing/registrations"
  end

  # Workflow endpoints delegate all state transitions to idempotent commands.
  resources :registrations, only: :show, controller: "ticketing/registrations"
  post "registrations/:id/release", to: "orders/registration_checkouts#create"

  resources :registrations, only: [] do
    member do
      post :approve, controller: "ticketing/registration_decisions"
      post :reject, controller: "ticketing/registration_decisions"
      post :reconsider, controller: "ticketing/registration_decisions"
    end
  end

  resources :ticket_types, only: [] do
    post :offer_next, on: :member, controller: "ticketing/waitlist_offers"
  end

  post "events/:event_id/complimentary_tickets", to: "ticketing/complimentary_tickets#create"

  resources :events, only: [] do
    resources :event_products, only: [] do
      resource :ticket_type, only: %i[show create update destroy], controller: "ticketing/ticket_types" do
        resources :access_codes, only: %i[index show create destroy], controller: "ticketing/access_codes"
        resources :invitations, only: %i[index show create destroy], controller: "ticketing/invitations"
      end
    end
  end

  post "ticketing/audience_authorizations", to: "ticketing/audience_authorizations#create"
  post "events/:event_id/scanner_invitations", to: "ticketing/scanner_invitations#create"
  get "events/:event_id/scanners", to: "ticketing/scanner_rosters#index"
  patch "events/:event_id/scanner_device_assignments/:id", to: "ticketing/scanner_device_assignments#update"
  resources :scanner_invitations, only: [], controller: "ticketing/scanner_invitations" do
    post :resend, on: :member
    post :reset_pairing, on: :member
    post :revoke, on: :member
  end
  get "organizations/:organization_id/scanner_devices", to: "ticketing/scanner_devices#index"
  post "scanner/pair", to: "ticketing/scanner/pair#create"
  resources :scanner_devices, only: [] do
    post :revoke, on: :member, controller: "ticketing/scanner_devices"
  end
  get "scanner/events/:event_id/sync", to: "ticketing/scanner/event_sync#show"
  post "scanner/events/:event_id/scan_uploads", to: "ticketing/scanner/scan_uploads#create"
  post "scanner/events/:event_id/lookups", to: "ticketing/scanner/lookups#create"
  post "scanner/events/:event_id/verifications", to: "ticketing/scanner/verifications#create"
  post "checkin_logs/:id/identity_override", to: "ticketing/checkin_identity_overrides#create"
  post "checkin_logs/:id/admission_use_reversal", to: "ticketing/admission_use_reversals#create"

  resources :tickets, only: :index, controller: "ticketing/tickets" do
    resources :stream_sessions, only: :create, controller: "ticketing/stream_sessions"
    post :resale, on: :member, controller: "marketplace/resale_listings", action: :create
    resource :suspension, only: :create, controller: "ticketing/suspensions" do
      post :restore
      post :resolve
    end
    resource :delegation, only: :create, controller: "ticketing/delegations" do
      post :cancel
      patch :reassign
    end
    resources :credential_claims, only: :create, controller: "ticketing/credential_claims"
    resources :transfers, only: :create, controller: "ticketing/transfers"
  end

  resources :stream_sessions, only: [] do
    post :refresh, on: :member, controller: "ticketing/stream_sessions"
    post :revoke, on: :member, controller: "ticketing/stream_sessions"
  end

  post "tickets/:ticket_id/cancel", to: "ticketing/cancellations#create"

  resources :resale_listings, only: %i[index show], controller: "marketplace/resale_listings" do
    get :mine, on: :collection
  end
  post "resale_listings/:resale_listing_id/purchase", to: "marketplace/resale_purchases#create"
  post "resale_listings/:id/cancel", to: "marketplace/resale_listings#cancel"
  resource :resale_policy, only: %i[show update],
           path: "ticket_types/:ticket_type_id/resale_policy",
           controller: "marketplace/resale_policies"

  scope path: :marketplace do
    get "seller/balance", to: "marketplace/seller_reports#balance"
    get "seller/history", to: "marketplace/seller_reports#history"
    scope path: "seller" do
      resources :payout_accounts, only: %i[index create], controller: "marketplace/seller_payout_accounts" do
        get :destinations, on: :collection
        post :set_default, on: :member
      end
      resources :payouts, only: %i[index show create], controller: "marketplace/seller_payouts"
    end
  end

  resources :credential_claims, only: [] do
    post :accept, on: :member, controller: "ticketing/credential_claims"
  end

  resources :ticket_transfers, only: [] do
    post :accept, on: :member, controller: "ticketing/transfers"
    post :decline, on: :member, controller: "ticketing/transfers"
    post :cancel, on: :member, controller: "ticketing/transfers"
  end

  resources :refunds, only: %i[index show], controller: "orders/refunds"

  scope path: :finance, module: :finance do
    resources :organizations, only: [] do
      resources :payout_accounts, only: %i[index create], controller: "payout_accounts" do
        post :verify, on: :member
        post :set_default, on: :member
        post :suspend, on: :member
        post :close, on: :member
      end
      resources :payouts, only: %i[index show create], controller: "payouts" do
        post :dispatch, on: :member, action: :dispatch_payout
        post :reconcile, on: :member
      end
    end
    get "organizations/:organization_id/ledger_entries", to: "payouts#ledger_entries"
    get "organizations/:organization_id/balance", to: "payouts#balance"
    post "payouts/:id/approve_no_balance_api", to: "payouts#approve_no_balance_api"
    put "reserve_policies/:provider/:currency", to: "payouts#update_reserve_policy"
  end

  namespace :admin do
    get "system/readiness", to: "system/readiness#show"

    namespace :marketplace do
      resources :seller_payout_accounts, only: %i[index show], controller: "seller_payout_accounts" do
        post :verify, on: :member
      end

      resources :seller_payouts, only: %i[index show], controller: "seller_payouts" do
        post :dispatch, on: :member, action: :dispatch_payout
        post :reconcile, on: :member
      end
    end

    namespace :commercial do
      resources :fee_schedules, only: %i[index show create update] do
        resources :fee_schedule_versions, only: %i[index create], controller: "fee_schedule_versions"
      end
      resources :fee_schedule_versions, only: %i[show update], controller: "fee_schedule_versions" do
        member do
          post :simulate
          post :submit
          post :approve
          post :reject
          post :schedule
          post :activate
          post :terminate
          post :deliver_notice
        end
      end
      resources :programs, only: %i[index show create update]
      resources :assignments, only: %i[index show create] do
        member do
          post :submit
          post :approve
          post :reject
          post :activate
          post :terminate
        end
      end
      resources :simulations, only: %i[index show create]
      resources :subsidy_budgets, only: %i[index show create update]
    end

    resources :users, except: %i[new edit] do
      member do
        post :deactivate
        post :reactivate
      end
      resources :roles, only: %i[index create destroy], controller: "user_roles", param: :role_id
    end
    resources :roles, except: %i[new edit]
    resources :permissions, except: %i[new edit]
    resources :categories, except: %i[new edit]
    resources :venues, except: %i[new edit]
    resources :artists, except: %i[new edit]
    resources :events, except: %i[new edit] do
      member do
        post :publish
        post :unpublish
      end
    end
    resources :organizations, except: %i[new edit] do
      member do
        post :transfer_ownership
        get "documents/:document_type", to: "organizations#download", as: :download_document
      end
      resources :memberships, only: %i[index show create update destroy]
    end

    resources :legal_documents, except: %i[new edit] do
      member do
        post :publish
        post :activate
        post :deactivate
      end
    end
    resources :data_retention_policies, except: %i[new edit destroy]
    resources :data_retention_holds, only: %i[index show create] do
      member do
        post :release
      end
    end

    post "organizations/:id/verification/approve",              to: "verifications#approve"
    post "organizations/:id/verification/reject",               to: "verifications#reject"
    post "organizations/:id/verification/request_modification", to: "verifications#request_modification"
  end

  scope module: :organizations do
    post "organizations/membership_invitations/claim", to: "owner_membership_invitations#claim"
    post "organizations/membership_invitations/preview", to: "owner_membership_invitations#preview"

    resources :owner_organizations, only: %i[index show create update destroy],
              path: "organizations/owner" do
      resources :memberships, only: %i[index show update destroy],
                controller: "owner_memberships" do
        member do
          patch :suspend
          patch :activate
        end
      end
      resources :membership_invitations, only: %i[index create], controller: "owner_membership_invitations" do
        post :resend, on: :member
        post :revoke, on: :member
      end
      get :team_roster, on: :member, to: "owner_team_rosters#show"
      member do
        patch :documents
        get "documents/:document_type", to: "owner_organizations#download", as: :download_document
      end
    end

    post "organizations/owner/:organization_id/verification/submit",   to: "verifications#submit"
    post "organizations/owner/:organization_id/verification/resubmit", to: "verifications#resubmit"

    resources :organizations, only: %i[index show], path: "organizations"
  end

  scope path: :commercial, module: :commercial do
    get "organizations/:organization_id/terms", to: "organization_terms#show",
      as: :commercial_organization_terms
    resources :events, only: [] do
      resources :event_payer_selections, only: %i[index show create]
    end
  end

  scope module: :core do
    get "users/:user_id/following", to: "follows#following"
    get "feed", to: "feed#index"
  end

  constraints(lambda do |request|
    config = Rails.application.config.x.short_links
    request.host == config.host &&
      (config.port.blank? || request.port == config.port.to_i)
  end) do
    get "/:slug", to: "links/redirects#show", as: :branded_redirect
  end
end
