# Lessons

- For pre-launch invitation delivery, use the hybrid boundary: persist the
  one-time token encrypted alongside its lookup digest, publish only the
  invitation ID through the outbox, and let a provider-injection job decrypt
  and delegate delivery. Do not build a mail/SMS adapter before Messaging owns
  that integration.
