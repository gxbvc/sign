# frozen_string_literal: true

# The GXB API operation routes, /gxb/v1/* (manifest: lib/gxb_api_manifest.rb; logic: lib/gxb_api_operations.rb).
# First-use provisioning (implementation plan 4.2): a write operation (POST) finds or makes the person's Sign
# account before it runs. A read (GET) never writes: it uses the existing account, or sees an empty one.
module GxbApi
  class OperationsController < ActionController::API
    include GxbApiAuthenticatable

    wrap_parameters false

    before_action :resolve_person

    # Declared first, so the specific handlers below win.
    rescue_from StandardError do |e|
      Rails.logger.error("GXB API operation #{action_name} failed: #{e.class}")
      gxb_api_error(500, 'internal_error', 'the operation failed')
    end
    rescue_from GxbChatTools::NotFound, ActiveRecord::RecordNotFound, CanCan::AccessDenied do
      # "Missing" and "not yours" are the same answer.
      gxb_api_error(404, 'not_found', 'not found')
    end
    rescue_from GxbChatTools::Invalid, ActiveRecord::RecordInvalid do |e|
      gxb_api_error(422, 'invalid_arguments', e.message.truncate(1000))
    end
    rescue_from GxbApiOperations::Conflict do |e|
      gxb_api_error(409, 'confirmation_mismatch', e.message)
    end
    rescue_from ActionDispatch::Http::Parameters::ParseError do
      gxb_api_error(400, 'bad_json', 'the body is not valid JSON')
    end

    def template_list
      render json: GxbApiOperations.template_list(@user, query)
    end

    def template_get
      render json: GxbApiOperations.template_get(@user, query.merge('template_id' => params[:template_id]))
    end

    def document_list
      render json: GxbApiOperations.document_list(@user, query)
    end

    def signature_request_preview
      render json: GxbApiOperations.signature_request_preview(@user, query)
    end

    def template_create
      once('sign.template.create') { [201, GxbApiOperations.template_create(@user, body)] }
    end

    def signature_request_create
      once('sign.signature_request.create') { [201, GxbApiOperations.signature_request_create(@user, body)] }
    end

    private

    def resolve_person
      @user =
        if GxbApiAuthenticatable::READ_METHODS.include?(request.method)
          GxbApiAccounts.lookup(@gxb_api_claims)
        else
          GxbApiAccounts.find_or_create!(@gxb_api_claims)
        end
    rescue GxbApiAccounts::Refused => e
      gxb_api_error(403, e.code, e.message)
    end

    def query
      request.query_parameters.to_h
    end

    def body
      request.request_parameters.to_h
    end

    # Runs a create or send once per Idempotency-Key (GxbApiIdempotency). Errors inside become JSON answers here,
    # so a clean refusal frees the key.
    def once(operation_id)
      status, json = GxbApiIdempotency.run(user: @user, operation_id:, key: request.headers['Idempotency-Key'],
                                           arguments: body) do
        yield
      rescue GxbChatTools::NotFound, ActiveRecord::RecordNotFound, CanCan::AccessDenied
        [404, error_body('not_found', 'not found')]
      rescue GxbChatTools::Invalid, ActiveRecord::RecordInvalid => e
        [422, error_body('invalid_arguments', e.message.truncate(1000))]
      rescue GxbApiOperations::Conflict => e
        [409, error_body('confirmation_mismatch', e.message)]
      end

      render json:, status:
    end

    def error_body(code, message)
      { error: { code:, message: } }
    end
  end
end
