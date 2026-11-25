# frozen_string_literal: true

# GXB: one row per (user, GXB API operation, Idempotency-Key), so a repeat of a create or a send runs once and
# gets the first answer. Only a SHA-256 of the key and of the arguments is stored. Listed in deploy/release.json
# gxb_migrations.
class CreateGxbApiIdempotencyKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :gxb_api_idempotency_keys do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :operation_id, null: false
      t.string :key_digest, null: false
      t.string :request_digest, null: false
      t.integer :response_status
      t.text :response_body

      t.timestamps
    end

    add_index :gxb_api_idempotency_keys, %i[user_id operation_id key_digest],
              unique: true, name: 'index_gxb_api_idempotency_keys_unique'
    add_index :gxb_api_idempotency_keys, :created_at
  end
end
