Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  scope module: :core do
    post "auth/login", to: "auth#login"
    post "auth/signup", to: "auth#signup"
    post "auth/refresh", to: "auth#refresh"
    post "auth/logout", to: "auth#logout"
    get "auth/me", to: "auth#me"
  end

  namespace :events do
    resources :categories, only: %i[index show]
    resources :venues, only: %i[index show] do
      member do
        post :follow
        post :unfollow
        get :followers
      end
    end
    resources :artists, only: %i[index show] do
      member do
        post :follow
        post :unfollow
        get :followers
      end
    end
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

      resources :memberships, only: %i[index show create update destroy],
                controller: "organization_memberships"
    end
  end

  namespace :organizations do
    resources :organizations, only: %i[index show] do
      member do
        post :follow
        post :unfollow
        get :followers
      end
    end

    get    "owner",               to: "owner_organizations#index"
    post   "owner",               to: "owner_organizations#create",   as: :owner_organizations
    get    "owner/:id",           to: "owner_organizations#show"
    patch  "owner/:id",           to: "owner_organizations#update",   as: :owner_organization
    put    "owner/:id",           to: "owner_organizations#update"
    delete "owner/:id",           to: "owner_organizations#destroy"

    resources :memberships, except: %i[new edit], controller: "memberships",
              path: "organizations/:organization_id/memberships",
              as: :organization_memberships
  end

  scope module: :core do
    get "users/:user_id/following", to: "follows#following"
    get "feed", to: "feed#index"
  end
end
