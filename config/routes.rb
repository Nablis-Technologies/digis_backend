Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  scope module: :core do
    post "auth/login", to: "auth#login"
    post "auth/signup", to: "auth#signup"
    post "auth/refresh", to: "auth#refresh"
    post "auth/logout", to: "auth#logout"
    get "auth/me", to: "auth#me"
  end

  scope ":followable_type", constraints: { followable_type: %r{venues|artists|organizations} } do
    scope ":followable_id" do
      post   "follow",    to: "core/follows#create",    as: :follow
      delete "follow",    to: "core/follows#destroy"
      get    "followers", to: "core/followers#index",   as: :followers
    end
  end

  scope module: :events do
    resources :categories, only: %i[index show]
    resources :venues, only: %i[index show]
    resources :artists, only: %i[index show]
  end

  namespace :admin do
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
    resources :organizations, except: %i[new edit] do
      member do
        post :transfer_ownership
      end
      resources :memberships, only: %i[index show create update destroy]
    end
  end

  scope module: :organizations do
    resources :owner_organizations, only: %i[index show create update destroy],
              path: "organizations/owner" do
      resources :memberships, only: %i[index show create update destroy],
                controller: "owner_memberships"
    end

    resources :organizations, only: %i[index show], path: "organizations"
  end

  scope module: :core do
    get "users/:user_id/following", to: "follows#following"
    get "feed", to: "feed#index"
  end
end
