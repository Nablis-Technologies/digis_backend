# AUTHENTICATION & IDENTITY ARCHITECTURE

**Date**: May 17, 2026
**Context**: Event ticketing platform — Ethiopia market, phone-first, frictionless purchase

---

## CORE PRINCIPLE: THERE ARE NO GUESTS

Every ticket purchase creates a `User` record. The difference between a "guest buyer" and a "registered user" is not existence — it's **completion state**.

```
Shadow (phone only)  →  Verified (phone + OTP)  →  Complete (profile + password)
```

This eliminates the hardest problem in ticketing: **orphaned tickets**. Tickets are always owned by a User from the moment of purchase. There's no "claiming" step, no "guest purchase" table, no reconciliation job.

---

## IDENTITY MODEL

### The User Record Is Always Created — Profile Completes Over Time

| State | `phone` | `verified` | `profile_complete` | `password` | Can buy? | Can resell? | Can transfer? |
|-------|---------|------------|--------------------|------------|----------|-------------|---------------|
| Shadow (purchase-only) | ✅ | `false` | `false` | `nil` | ✅ | ❌ | ❌ |
| Verified (OTP done) | ✅ | `true` | `false` | `nil` | ✅ | ✅ | ✅ |
| Complete (profile + password) | ✅ | `true` | `true` | set | ✅ | ✅ | ✅ |
| Complete + OAuth | ✅ | `true` | `true` | optional | ✅ | ✅ | ✅ |

### The Three Gates

1. **Phone** — required for everything. Creates the account.
2. **Verification (OTP)** — required for resale, transfer, following, rating. One-time only.
3. **Profile completion** — required for nothing, but unlocks the full experience. Collected during sign-up onboarding or after verification.

### Key Insight

Profile fields (first name, last name, date of birth) are **inline on the users table**, not a separate `user_profiles` table. Why:
- Always accessed with the user (no N+1)
- Simple queries (`User.where(first_name: ...)`)
- No join complexity for recommendations, search, or analytics
- Follows the 37signals principle: "one table until you need two"

---

## DATA MODEL

```ruby
# db/migrate/XXXX_create_core_users.rb (updated)
create_table :core_users, id: :uuid do |t|
  # ── Primary identity (required) ──
  t.string :phone, limit: 30, null: false

  # ── Secondary identity (optional) ──
  t.string :email, limit: 150

  # ── Profile (optional — collected during onboarding) ──
  t.string :first_name
  t.string :last_name
  t.date :date_of_birth
  t.string :avatar_url

  # ── Verification state ──
  t.boolean :verified, null: false, default: false
  t.datetime :verified_at

  # ── Profile completion flag ──
  t.boolean :profile_complete, null: false, default: false

  # ── Authentication (optional — set when user chooses a password) ──
  t.string :password_digest

  # ── OAuth providers (optional) ──
  t.string :google_uid
  t.string :apple_uid

  # ── OTP (transient — cleared after verification) ──
  t.string :otp_code
  t.datetime :otp_expires_at
  t.integer :otp_attempts, default: 0

  # ── Metadata ──
  t.datetime :last_login_at
  t.string :last_device_id

  t.timestamps
end

add_index :core_users, :phone, unique: true
add_index :core_users, :email, unique: true, where: "email IS NOT NULL"
add_index :core_users, :google_uid, unique: true, where: "google_uid IS NOT NULL"
add_index :core_users, :apple_uid, unique: true, where: "apple_uid IS NOT NULL"
add_index :core_users, :verified
add_index :core_users, :profile_complete
```

### Why This Works

- **`phone` is the anchor** — always present, always unique
- **`verified` is the gate** — controls access to resale, transfer, account management
- **`profile_complete` is the experience flag** — tells the frontend whether to show onboarding
- **Profile fields are nullable** — shadow users don't have them, verified users may not yet, complete users do
- **`password_digest` is optional** — users can operate with phone-only auth indefinitely
- **OAuth UIDs are separate columns** — simple, no polymorphic complexity

---

## AUTHENTICATION FLOWS

### Flow 1: Frictionless Purchase (No Account Required)

```
POST /api/v1/orders
{
  phone: "+251911234567",
  ticket_type_id: "uuid",
  quantity: 2,
  payment: { provider: "telebirr", ... }
}
```

**Server-side:**
```ruby
# 1. Find or create shadow user (no profile, no password)
user = Core::User.find_or_initialize_by(phone: normalized_phone)
if user.new_record?
  user.verified = false
  user.profile_complete = false
  user.save!
end

# 2. Create order and tickets (owned by this user)
order = Order.create!(user: user, ...)
tickets = order.tickets

# 3. Send SMS with ticket details + verification prompt
SmsService.send_ticket_confirmation(phone: user.phone, tickets: tickets)
# SMS: "You bought 2 tickets for [Event]. QR: [link]. Verify your phone to manage them: [short-link]"

# 4. Return order confirmation
render json: { order: order, tickets: tickets }
```

**What the user experiences:**
- Enter phone → select tickets → pay → done
- No OTP, no password, no profile form, no account creation screen
- SMS arrives with tickets + optional verification link

---

### Flow 2: Direct Sign-Up (Onboarding Flow)

This is for users who proactively create an account **before** buying anything.

```
Step 1: Enter phone
POST /api/v1/auth/request-otp
{ phone: "+251911234567" }
→ Sends 6-digit OTP via SMS

Step 2: Verify OTP
POST /api/v1/auth/verify-otp
{ phone: "+251911234567", otp: "123456" }
→ Verifies OTP
→ Sets verified: true, verified_at: now
→ Returns JWT tokens + onboarding_required: true

Step 3: Complete profile (onboarding)
POST /api/v1/auth/complete-profile
Authorization: Bearer <JWT>
{
  first_name: "Adoniyas",
  last_name: "Tadesse",
  date_of_birth: "1995-03-15",
  password: "...",
  password_confirmation: "..."
}
→ Sets first_name, last_name, date_of_birth, password_digest
→ Sets profile_complete: true
→ Returns updated user + tokens
```

**What the user experiences:**
- Enter phone → receive SMS → enter 6-digit code → fill profile form → set password → done
- One continuous flow: phone → OTP → profile → password → home screen
- After this, they're a **complete** user with full access

**Server-side:**
```ruby
def complete_profile
  current_user.assign_attributes(profile_params)
  current_user.profile_complete = true

  if current_user.save
    render_success("Profile completed", data: {
      user: current_user,
      onboarding_required: false
    }, serializer_options: { user: { serializer: Core::UserAuthSerializer } })
  else
    render_error("Profile update failed", errors: current_user.errors.full_messages, status: :unprocessable_entity)
  end
end

private

def profile_params
  params.require(:user).permit(
    :first_name, :last_name, :date_of_birth,
    :password, :password_confirmation
  )
end
```

---

### Flow 3: Shadow User → Verified (After Purchase)

Triggered when a shadow user (who bought tickets without signing up) decides to manage their tickets.

```
Step 1: Enter phone → request OTP
POST /api/v1/auth/request-otp
{ phone: "+251911234567" }
→ System finds existing shadow user
→ Sends OTP

Step 2: Verify OTP
POST /api/v1/auth/verify-otp
{ phone: "+251911234567", otp: "123456" }
→ Sets verified: true
→ Returns JWT tokens + onboarding_required: true (profile still incomplete)

Step 3: Complete profile (onboarding — same as Flow 2, Step 3)
POST /api/v1/auth/complete-profile
Authorization: Bearer <JWT>
{ first_name: "...", last_name: "...", date_of_birth: "...", password: "..." }
→ Sets profile_complete: true
→ All their previously purchased tickets are now visible in their account
```

**Key point**: The user's tickets were **already owned** by their shadow user. After verification and profile completion, they see the same tickets — no migration, no claim process.

**What the user experiences:**
- "I bought tickets earlier, now I want to manage them"
- Enter same phone → OTP → fill profile → set password → "Here are your tickets"

---

### Flow 4: Subsequent Login (Complete User Returns)

Once verified and profile-complete, the user has multiple login options:

#### Option A: Phone + Password
```
POST /api/v1/auth/login
{ phone: "+251911234567", password: "..." }
→ Authenticates with bcrypt
→ Returns JWT tokens + onboarding_required: false
```

#### Option B: Phone + OTP (if they never set a password)
```
POST /api/v1/auth/login
{ phone: "+251911234567" }
→ Sends OTP → User enters OTP → gets tokens
→ onboarding_required: depends on profile_complete
```

#### Option C: Email + Password (if they added email)
```
POST /api/v1/auth/login
{ email: "user@example.com", password: "..." }
→ Finds user by email → authenticates → returns tokens
```

#### Option D: OAuth (if they linked Google/Apple)
```
POST /api/v1/auth/oauth/google
{ id_token: "..." }
→ Validates Google token
→ Finds user by google_uid
→ If not found but phone matches existing user → links Google to existing account
→ Returns tokens
```

**Key rule**: OAuth login still requires a phone number. If the OAuth provider doesn't supply one, prompt the user to add it.

---

### Flow 5: Gifted Ticket Received

```
Organizer gifts ticket to "+251911987654"
→ System finds or creates User(phone: "+251911987654", verified: false, profile_complete: false)
→ Assigns ticket to that user
→ Sends SMS: "You received a ticket for [Event]! View: [link]"
```

If the recipient later verifies their phone or creates an account, the ticket is already there. No claim process needed.

---

## AUTHORIZATION GATES

### What Requires What

| Action | Auth Required | Verified Required | Profile Required |
|--------|--------------|-------------------|------------------|
| Buy ticket | No (phone only) | No | No |
| View ticket via link | No (QR/token) | No | No |
| Resell ticket | Yes (JWT) | Yes | No |
| Transfer ticket | Yes (JWT) | Yes | No |
| Follow organizer/venue | Yes (JWT) | Yes | No |
| Rate event | Yes (JWT) | Yes | No |
| View purchase history | Yes (JWT) | No | No |
| Update profile | Yes (JWT) | Yes | No |
| Delete account | Yes (JWT) | Yes | Yes |
| SMS campaign opt-out | Yes (JWT) | Yes | No |

### Implementation

```ruby
class Api::V1::ResaleListingsController < Core::ApplicationController
  before_action :require_verified_user, only: %i[create update destroy cancel]

  private

  def require_verified_user
    return if current_user&.verified?

    render_error("Phone verification required to resell tickets",
                 status: :forbidden, code: "verification_required",
                 meta: { action: "verify_phone", phone: current_user&.phone })
  end
end
```

### Frontend Onboarding Gate

The frontend uses `onboarding_required` in the login/verify response to decide whether to show the profile completion screen:

```json
{
  "success": true,
  "data": {
    "user": { ... },
    "onboarding_required": true
  }
}
```

If `onboarding_required: true`, the app redirects to the profile completion screen. If `false`, it goes to the home screen.

---

## SECURITY CONSIDERATIONS

### 1. SIM Swapping

**Risk**: Attacker gets a new SIM with the victim's phone number, then verifies and claims their account.

**Mitigations**:
- OTP is only required for **first-time verification**. After that, password or OAuth is required.
- If a user has set a password, phone-only login is disabled — they must use password or OAuth.
- Add a "suspicious login" notification via SMS when a new device logs in.

**Residual risk**: If a user is verified but hasn't set a password, SIM swap gives access. Mitigation: encourage password setup during onboarding.

### 2. Phone Number Reuse

**Risk**: Telecom recycles a phone number. New owner gets the old owner's tickets.

**Mitigations**:
- Once a user is verified AND has set a password, the account is locked to that password.
- If a user is verified but has no password, the new SIM owner could verify and access the account. Mitigation: encourage password setup during onboarding.

### 3. OTP Brute Force

**Risk**: Attacker tries all 1,000,000 OTP combinations.

**Mitigations**:
- Max 3 attempts per OTP request
- OTP expires in 5 minutes
- Rate limit: max 3 OTP requests per phone per hour
- Lock phone for 30 minutes after 3 failed OTP requests

### 4. Phone Number Enumeration

**Risk**: Attacker uses login flow to check if a phone number exists in the system.

**Mitigations**:
- Return the same response whether the phone exists or not: "If this phone is registered, you'll receive a code."

### 5. Profile Data Privacy

**Risk**: Date of birth is sensitive personal data.

**Mitigations**:
- Never expose `date_of_birth` in API responses (only in user's own profile view)
- Use it for age-restricted events (18+, 21+) without exposing the actual date
- Store as `date` type (not `datetime`) — no time component needed

---

## SESSION & TOKEN STRATEGY

### Access Token (JWT)
```ruby
{
  user_id: "uuid",
  phone: "+251911...",
  verified: true,
  profile_complete: true,
  type: "access",
  roles: ["user"],
  exp: 15.minutes.from_now
}
```

### Refresh Token (DB-stored, rotated)
```ruby
# Already implemented — rotation is working
# 30-day expiry, device-bound
```

### Ticket View Token (short-lived, no user session)
```ruby
{
  ticket_id: "uuid",
  type: "ticket_view",
  exp: 24.hours.from_now
}
```

---

## IMPLEMENTATION PLAN

### Phase 1: Update User Model (Day 1)

```ruby
# Migration: update_core_users_for_ticketing
add_column :core_users, :first_name, :string
add_column :core_users, :last_name, :string
add_column :core_users, :date_of_birth, :date
add_column :core_users, :avatar_url, :string
add_column :core_users, :verified, :boolean, default: false, null: false
add_column :core_users, :verified_at, :datetime
add_column :core_users, :profile_complete, :boolean, default: false, null: false
add_column :core_users, :otp_code, :string
add_column :core_users, :otp_expires_at, :datetime
add_column :core_users, :otp_attempts, :integer, default: 0
add_column :core_users, :google_uid, :string
add_column :core_users, :apple_uid, :string
add_column :core_users, :last_login_at, :datetime
add_index :core_users, :verified
add_index :core_users, :profile_complete
```

Make `password_digest` nullable:
```ruby
change_column_null :core_users, :password_digest, true
```

### Phase 2: User Model Updates

```ruby
# app/models/platform/user.rb (updated)
module Core
  class User < Core::ApplicationRecord
    include Core::UserAuthenticatable

    has_many :user_roles, class_name: "Core::UserRole", foreign_key: :user_id, dependent: :destroy, inverse_of: :user
    has_many :roles, through: :user_roles, class_name: "Core::Role"

    has_many :assigned_user_roles, class_name: "Core::UserRole", foreign_key: :assigned_by_id, dependent: :nullify, inverse_of: :assigned_by
    has_many :submitted_reviews, class_name: "Core::Review", as: :reviewed_by, dependent: :nullify

    # ── Ticketing associations (to be added) ──
    has_many :orders, class_name: "Order", foreign_key: :user_id, dependent: :destroy
    has_many :tickets, class_name: "Ticket", foreign_key: :owner_user_id, dependent: :nullify

    # ── Computed ──
    def full_name
      [first_name, last_name].compact.join(" ").presence || "User"
    end

    def display_name
      first_name.presence || full_name
    end

    def onboarding_required?
      !profile_complete?
    end

    # ── Ransack ──
    def self.ransackable_attributes(_auth_object = nil)
      %w[id email phone verified verified_at profile_complete first_name last_name created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[roles]
    end

    # ── RBAC methods (existing) ──
    def has_role?(role_code)
      active_role_codes.include?(role_code.to_s.upcase)
    end

    def has_permission?(permission_code)
      return true if super_admin?
      active_permissions.include?(permission_code.to_s)
    end

    alias can? has_permission?

    def has_all_permissions?(*permission_codes)
      permission_codes.flatten.all? { |code| has_permission?(code) }
    end

    def has_any_permission?(*permission_codes)
      permission_codes.flatten.any? { |code| has_permission?(code) }
    end

    def super_admin?
      has_role?("SUPER_ADMIN")
    end

    def active_permissions
      @active_permissions ||= Core::Permission
        .joins(role_permissions: { role: :user_roles })
        .where(core_user_roles: { user_id: id })
        .where(core_roles: { active: true }, core_permissions: { active: true })
        .where("core_user_roles.expires_at IS NULL OR core_user_roles.expires_at > ?", Time.current)
        .distinct
        .pluck(:code)
    end

    def active_role_codes
      @active_role_codes ||= roles
        .where(active: true)
        .joins(:user_roles)
        .where(core_user_roles: { user_id: id })
        .where("core_user_roles.expires_at IS NULL OR core_user_roles.expires_at > ?", Time.current)
        .distinct
        .pluck(:code)
    end

    def clear_permission_cache!
      @active_permissions = nil
      @active_role_codes = nil
    end
  end
end
```

### Phase 3: OTP Service (Day 1-2)

```ruby
# app/services/platform/otp_service.rb
class Core::OtpService
  def self.request(phone)
    user = Core::User.find_or_initialize_by(phone: normalize(phone))
    user.verified = false if user.new_record?
    user.profile_complete = false if user.new_record?
    user.save!

    user.update!(
      otp_code: rand(100_000..999_999).to_s,
      otp_expires_at: 5.minutes.from_now,
      otp_attempts: 0
    )

    SmsService.send_otp(phone: user.phone, code: user.otp_code)
    { success: true, message: "Code sent" }
  end

  def self.verify(phone:, otp:)
    user = Core::User.find_by!(phone: normalize(phone))

    raise AuthenticationError, "Too many attempts", code: "otp_max_attempts" if user.otp_attempts >= 3
    raise AuthenticationError, "Code expired", code: "otp_expired" if user.otp_expires_at.past?
    raise AuthenticationError, "Invalid code", code: "invalid_otp" unless secure_compare(user.otp_code, otp)

    user.update!(
      verified: true,
      verified_at: Time.current,
      otp_code: nil,
      otp_expires_at: nil,
      otp_attempts: 0
    )

    user
  end

  def self.normalize(phone)
    phone.to_s.strip.gsub(/\D/, "").sub(/^0/, "+251")
  end

  def self.secure_compare(a, b)
    ActiveSupport::SecurityUtils.secure_compare(a.to_s, b.to_s)
  end
end
```

### Phase 4: Auth Controller Updates (Day 2-3)

```ruby
# app/controllers/platform/auth_controller.rb (updated)
class Core::AuthController < Core::ApplicationController
  skip_before_action :authenticate_user, only: %i[request_otp verify_otp login signup refresh]
  skip_before_action :authorize_action!, only: %i[request_otp verify_otp login signup refresh]

  # ── Request OTP ──
  def request_otp
    skip_authorization
    result = Core::OtpService.request(params[:phone])
    render_success(result[:message])
  end

  # ── Verify OTP → get tokens ──
  def verify_otp
    skip_authorization
    user = Core::OtpService.verify(phone: params[:phone], otp: params[:otp])
    tokens = sign_in(user, request)
    render_success("Phone verified", data: {
      user: user,
      access_token: tokens[:access_token],
      refresh_token: tokens[:refresh_token].refresh_token,
      onboarding_required: user.onboarding_required?
    }, serializer_options: { user: { serializer: Core::UserAuthSerializer } })
  end

  # ── Complete profile (onboarding) ──
  def complete_profile
    current_user.assign_attributes(profile_params)
    current_user.profile_complete = true

    if current_user.save
      render_success("Profile completed", data: {
        user: current_user,
        onboarding_required: false
      }, serializer_options: { user: { serializer: Core::UserAuthSerializer } })
    else
      render_error("Profile update failed", errors: current_user.errors.full_messages, status: :unprocessable_entity)
    end
  end

  # ── Password login ──
  def login
    skip_authorization
    user = if params[:email].present?
             Core::User.find_by(email: params[:email].downcase)
           else
             Core::User.find_by(phone: params[:phone])
           end

    if user&.authenticate(params[:password])
      tokens = sign_in(user, request)
      render_success("Login successful", data: {
        user: user,
        access_token: tokens[:access_token],
        refresh_token: tokens[:refresh_token].refresh_token,
        onboarding_required: user.onboarding_required?
      }, serializer_options: { user: { serializer: Core::UserAuthSerializer } })
    else
      render_error("Invalid credentials", status: :unauthorized, code: "invalid_credentials")
    end
  end

  # ── Signup (with optional profile) ──
  def signup
    skip_authorization
    user = Core::User.new(user_params)

    # If no password provided, create as unverified shadow account
    if user_params[:password].blank?
      user.verified = false
      user.profile_complete = false
    end

    if user.save
      assign_default_role(user)
      render_success("Account created", data: {
        user: user.reload,
        onboarding_required: user.onboarding_required?
      }, status: :created, serializer_options: { user: { serializer: Core::UserAuthSerializer } })
    else
      render_error("Signup failed", errors: user.errors.full_messages, status: :unprocessable_entity, code: "signup_failed")
    end
  end

  # ── Set password (existing verified user) ──
  def set_password
    if current_user.update(password_params)
      render_success("Password set successfully")
    else
      render_error("Password update failed", errors: current_user.errors.full_messages, status: :unprocessable_entity)
    end
  end

  # ── Add email ──
  def add_email
    if current_user.update(email: params[:email])
      render_success("Email added successfully", data: { user: current_user })
    else
      render_error("Email update failed", errors: current_user.errors.full_messages, status: :unprocessable_entity)
    end
  end

  private

  def user_params
    params.require(:user).permit(:phone, :email, :first_name, :last_name, :date_of_birth, :password, :password_confirmation)
  end

  def profile_params
    params.require(:user).permit(:first_name, :last_name, :date_of_birth, :password, :password_confirmation)
  end

  def password_params
    params.require(:user).permit(:password, :password_confirmation)
  end
end
```

### Phase 5: Order Controller — Shadow User Creation (Day 3-4)

```ruby
# app/controllers/api/v1/orders_controller.rb
class Api::V1::OrdersController < Core::ApplicationController
  skip_before_action :authenticate_user, only: %i[create]
  skip_before_action :authorize_action!, only: %i[create]

  def create
    skip_authorization

    phone = normalize_phone(params[:phone])
    raise ArgumentError, "Phone number is required" if phone.blank?

    user = Core::User.find_or_initialize_by(phone: phone)
    if user.new_record?
      user.verified = false
      user.profile_complete = false
      user.save!
    end

    order = Order.new(user: user, ...)

    if order.save
      SmsService.send_ticket_confirmation(phone: user.phone, order: order)
      render_success("Order created", data: { order: order }, status: :created)
    else
      render_error("Order failed", errors: order.errors.full_messages, status: :unprocessable_entity)
    end
  end

  private

  def normalize_phone(phone)
    return nil if phone.blank?
    phone.to_s.strip.gsub(/\D/, "").sub(/^0/, "+251")
  end
end
```

### Phase 6: Serializer Updates (Day 5)

```ruby
# app/serializers/platform/user_auth_serializer.rb (updated)
class Core::UserAuthSerializer < ActiveModel::Serializer
  attributes :id, :email, :phone, :first_name, :last_name, :date_of_birth,
             :verified, :verified_at, :profile_complete, :created_at, :updated_at, :permissions

  has_many :roles, serializer: Core::RoleSerializer

  def permissions
    object.active_permissions.to_a
  end
end
```

---

## USER JOURNEY MAP

### Journey A: First-Time Buyer (Frictionless)

```
1. Sees event link → clicks "Buy Ticket"
2. Selects ticket type, quantity
3. Enters phone number: +251911234567
4. Pays via Telebirr
5. Receives SMS: "2 tickets for [Event]. QR: [link]. Verify phone to manage: [link]"
6. Done. Shadow account created. Tickets owned. No profile, no password.
```

### Journey B: Direct Sign-Up (Onboarding)

```
1. Opens app → clicks "Sign Up"
2. Enters phone number: +251911234567
3. Receives 6-digit OTP via SMS
4. Enters OTP → phone verified
5. **Onboarding screen appears**:
   - First name: "Adoniyas"
   - Last name: "Tadesse"
   - Date of birth: 1995-03-15
   - Set password: "••••••••"
6. Clicks "Complete" → profile_complete: true
7. Lands on home screen with full access
```

### Journey C: Shadow User → Verified → Complete (After Purchase)

```
1. Bought tickets earlier as shadow user (phone only, no profile)
2. Clicks "Manage my tickets" link from SMS
3. Enters phone number → receives OTP → verifies
4. **Onboarding screen appears** (profile still incomplete):
   - "Complete your profile to manage your tickets"
   - First name, last name, date of birth, set password
5. Clicks "Complete" → profile_complete: true
6. Lands on home screen → "Here are your 2 tickets for [Event]"
7. Can now resell, transfer, follow organizers
```

### Journey D: Gifted Ticket

```
1. Organizer gifts ticket to +251911987654
2. System creates/finds shadow user (verified: false, profile_complete: false)
3. SMS: "You received a ticket for [Event]! View: [link]"
4. Recipient clicks link → sees ticket (no login needed)
5. If they verify later → onboarding appears → profile completes → ticket in account
6. If they resell → must verify first
```

### Journey E: Returning Buyer (Already Complete)

```
1. Sees event link → clicks "Buy Ticket"
2. Enters phone number (same as before)
3. System recognizes phone → already verified, already complete
4. Pays via Telebirr
5. Receives SMS with new tickets
6. New tickets appear alongside old ones in their account
```

---

## COMPARISON: WHAT WE AVOIDED

| Approach | Problem | Our Solution |
|----------|---------|--------------|
| Guest purchases | Orphaned tickets, claim process needed | Always create User, no guests |
| OTP on every purchase | Friction kills conversion | OTP only on first verification |
| Email-first identity | Low email adoption in Ethiopia | Phone-first, email optional |
| Password required upfront | Friction for first-time buyers | Password collected during onboarding, optional for purchase |
| Separate user_profiles table | N+1 queries, join complexity | Inline profile fields on users table |
| "Claim tickets" flow | Complex, error-prone, support burden | Tickets always owned by User |
| Polymorphic OAuth | Complex joins, slow queries | Separate columns for each provider |

---

## SUMMARY

**The architecture is simple because it eliminates the guest/registered dichotomy entirely:**

1. **Every purchase creates a User** — shadow at first, verified after OTP, complete after onboarding
2. **Phone is the anchor** — always required, always unique
3. **Profile is collected during onboarding** — either during direct sign-up or after a shadow user verifies
4. **Verification and profile completion are separate gates** — verification unlocks resale/transfer, profile completion unlocks the full experience
5. **Tickets are never orphaned** — they're always owned by a User from creation
6. **Profile fields are inline** — no separate table, no joins, no complexity

This is how Stripe, Uber, and modern mobile-first platforms handle identity. It's frictionless for the buyer, secure for the platform, and eliminates the hardest edge cases in ticketing.
