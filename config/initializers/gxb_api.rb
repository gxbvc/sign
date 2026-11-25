# frozen_string_literal: true

# GXB API (api.gxb.vc) service routes. Registry line in the gxb/api repo: id sign, base_url https://sign.gxb.vc,
# audience https://api.sign.gxb.vc, class public, onboarding automatic_on_use. Every route needs an exchanged
# token (GxbApiAuthenticatable); AUTH_INTROSPECTION_SECRET comes from ENV. When it is blank, every request is 503.
ActiveSupport.on_load(:routes) do
  get 'openapi.json' => 'gxb_api/meta#manifest', format: false, as: :gxb_api_manifest
  get 'gxb/access' => 'gxb_api/meta#access', format: false, as: :gxb_api_access

  scope 'gxb/v1', module: 'gxb_api', controller: 'operations', format: false do
    get 'templates', action: :template_list
    post 'templates', action: :template_create
    get 'templates/:template_id', action: :template_get
    get 'documents', action: :document_list
    get 'signature_requests/preview', action: :signature_request_preview
    post 'signature_requests', action: :signature_request_create
  end
end
