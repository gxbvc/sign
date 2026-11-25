# frozen_string_literal: true

# A GXB API Idempotency-Key claim (service contract 4.4). See GxbApiIdempotency.
class GxbApiIdempotencyKey < ApplicationRecord
  belongs_to :user
end
