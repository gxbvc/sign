# frozen_string_literal: true

# Idempotency-Key for GXB API creates and sends (service contract 4.4). The first call with a key claims a row
# (unique per user, operation and key digest), runs, and stores its answer. A repeat with the same arguments gets
# that answer and runs nothing; with other arguments it is refused. A repeat while the first still runs gets 409.
# A clean refusal (4xx) frees the key so a fixed call can use it. An unexpected error keeps the row as an unknown
# outcome, so a retry can never send twice.
module GxbApiIdempotency
  KEEP = 7.days
  MAX_KEY_LENGTH = 255

  module_function

  # Yields and returns [status, body]. body is a Hash.
  def run(user:, operation_id:, key:, arguments:, &)
    return yield if key.blank?
    return error(422, 'bad_idempotency_key', 'Idempotency-Key is too long') if key.length > MAX_KEY_LENGTH

    request_digest = Digest::SHA256.hexdigest(canonical(arguments))
    row = claim(user, operation_id, Digest::SHA256.hexdigest(key), request_digest)
    return row if row.is_a?(Array)

    finish(row, &)
  end

  def claim(user, operation_id, key_digest, request_digest)
    GxbApiIdempotencyKey.where(user:, created_at: ...KEEP.ago).delete_all

    GxbApiIdempotencyKey.transaction(requires_new: true) do
      GxbApiIdempotencyKey.create!(user:, operation_id:, key_digest:, request_digest:)
    end
  rescue ActiveRecord::RecordNotUnique
    existing = GxbApiIdempotencyKey.find_by!(user:, operation_id:, key_digest:)

    if existing.request_digest != request_digest
      error(422, 'idempotency_key_reused', 'this Idempotency-Key was used with other arguments')
    elsif existing.response_status.nil?
      error(409, 'idempotency_in_progress', 'a call with this Idempotency-Key is still running')
    else
      [existing.response_status, JSON.parse(existing.response_body)]
    end
  end

  def finish(row)
    status, body = yield

    if status < 300
      row.update!(response_status: status, response_body: body.to_json)
    else
      row.destroy!
    end

    [status, body]
  rescue StandardError
    row.update!(response_status: 500, response_body: error(500, 'unknown_outcome',
                                                           'the first call with this key failed').last.to_json)
    raise
  end

  def canonical(value)
    JSON.generate(sorted(value))
  end

  def sorted(value)
    case value
    when Hash then value.to_h { |k, v| [k.to_s, sorted(v)] }.sort.to_h
    when Array then value.map { |v| sorted(v) }
    else value
    end
  end

  def error(status, code, message)
    [status, { error: { code:, message: } }]
  end
end
