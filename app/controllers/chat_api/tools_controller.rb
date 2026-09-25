# frozen_string_literal: true

# GET  /chat_api/tools -> { tools: [...] } for GXB Chat tool discovery.
# POST /chat_api/tools { tool, arguments } -> the tool result as JSON.
# ActionController::API: no Devise redirect, no CSRF, no session cookie. Errors are JSON.
module ChatApi
  class ToolsController < ActionController::API
    include ChatApiAuthenticatable

    wrap_parameters false

    def index
      render json: { tools: GxbChatTools.definitions }
    end

    def create
      tool = request.request_parameters['tool'].to_s
      return render(json: { error: 'Unknown tool' }, status: :not_found) unless GxbChatTools.tool?(tool)

      arguments = request.request_parameters.fetch('arguments', nil) || {}

      render json: GxbChatTools.call(tool, user: @chat_api_user, arguments:)
    rescue GxbChatTools::NotFound, ActiveRecord::RecordNotFound, CanCan::AccessDenied
      # "Missing" and "not yours" are the same answer.
      render json: { error: 'Not found' }, status: :not_found
    rescue GxbChatTools::Invalid, ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_content
    rescue ActionDispatch::Http::Parameters::ParseError
      render json: { error: 'Invalid JSON' }, status: :bad_request
    rescue StandardError => e
      # Chat shows the body to the model, so keep it JSON and short.
      Rails.logger.error("Chat tool #{tool.inspect} failed: #{e.class}: #{e.message}")
      render json: { error: 'Tool failed' }, status: :internal_server_error
    end
  end
end
