# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "securerandom"

BASE_URL = "https://digis-backend-preview.onrender.com"

def api_post(path, body, token = nil, idempotency_key = nil)
  uri = URI("#{BASE_URL}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 30

  req = Net::HTTP::Post.new(uri.path)
  req["Content-Type"] = "application/json"
  req["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
  req["Authorization"] = "Bearer #{token}" if token
  req["Idempotency-Key"] = idempotency_key if idempotency_key
  req.body = body.to_json if body

  res = http.request(req)
  parsed = JSON.parse(res.body) rescue { "raw" => res.body }
  [res.code.to_i, parsed]
end

def api_get(path, token = nil)
  uri = URI("#{BASE_URL}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 30

  req = Net::HTTP::Get.new(uri.path + (uri.query ? "?#{uri.query}" : ""))
  req["Content-Type"] = "application/json"
  req["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
  req["Authorization"] = "Bearer #{token}" if token

  res = http.request(req)
  parsed = JSON.parse(res.body) rescue { "raw" => res.body }
  [res.code.to_i, parsed]
end

# 1. Login Seller (Attendee: +251911000003)
puts "Logging in seller (attendee)..."
code, res = api_post("/auth/login", { "identifier" => "+251911000003", "password" => "password123" })
raise "Login failed: #{res}" unless code == 200
seller_token = res.dig("data", "access_token")
seller_id = res.dig("data", "user", "id")
puts "Seller logged in. ID: #{seller_id}"

# 2. Register for ticket
event_id = "01a088c6-64c3-7e97-9c13-1e94820f43fb"
ticket_type_id = "01a088c6-6d54-781f-a465-a049ad82f078"
product_id = "01a088c6-6d51-7ee5-b9df-312418e09c0a"

puts "\nSubmitting registration for seller..."
reg_idem = "reg-seller-#{SecureRandom.hex(6)}"
code, res = api_post(
  "/ticket_types/#{ticket_type_id}/registrations",
  {
    "phone" => "+251911000003",
    "package_quantity" => 1,
    "answers" => [{ "question_key" => "full_name", "value" => "Attendee Seller" }],
    "consents" => []
  },
  seller_token,
  reg_idem
)
raise "Registration failed: #{res}" unless code == 201
registration_id = res.dig("data", "registration", "id")
puts "Registration created. ID: #{registration_id}"

# 3. Request Quote
puts "\nRequesting order quote..."
code, res = api_post(
  "/events/#{event_id}/order_quotes",
  {
    "items" => [{
      "event_product_id" => product_id,
      "quantity" => 1,
      "registration_id" => registration_id
    }],
    "charge_currency" => "ETB",
    "provider" => "chapa",
    "payment_method" => "telebirr"
  },
  seller_token
)
raise "Quote failed: #{res}" unless code == 200
quote_token = res.dig("data", "quote_token")
total_minor = res.dig("data", "total_minor")
puts "Quote created. Total minor: #{total_minor}"

# 4. Create Order
puts "\nCreating primary order..."
order_idem = "ord-seller-#{SecureRandom.hex(6)}"
code, res = api_post(
  "/events/#{event_id}/orders",
  { "order" => { "quote_token" => quote_token } },
  seller_token,
  order_idem
)
raise "Order creation failed: #{res}" unless code == 201
order_id = res.dig("data", "id")
commercial_signature = res.dig("data", "commercial_signature")
puts "Order created. ID: #{order_id}"

# 5. Start Payment Attempt
puts "\nStarting payment attempt for primary order..."
pay_idem = "pay-seller-#{SecureRandom.hex(6)}"
code, res = api_post(
  "/orders/#{order_id}/payment_attempts",
  {
    "payment_attempt" => {
      "provider" => "chapa",
      "payment_method" => "telebirr",
      "commercial_signature" => commercial_signature
    }
  },
  seller_token,
  pay_idem
)
raise "Payment attempt failed: #{res}" unless code == 201
payment_id = res.dig("data", "id")
checkout_url = res.dig("data", "checkout_url")
puts "Payment attempt created. ID: #{payment_id}"
puts "CHECKOUT URL: #{checkout_url}"

File.write("scratch/primary_checkout_info.json", JSON.pretty_generate({
  seller_token: seller_token,
  seller_id: seller_id,
  order_id: order_id,
  payment_id: payment_id,
  checkout_url: checkout_url
}))
puts "Checkout info saved to scratch/primary_checkout_info.json"
