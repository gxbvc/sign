# frozen_string_literal: true

# GXB Chat host API (ChatApi::ToolsController). CHAT_API_KEY comes from ENV. When it is blank, every request is 401.
ActiveSupport.on_load(:routes) do
  get 'chat_api/tools' => 'chat_api/tools#index', as: :chat_api_tools
  post 'chat_api/tools' => 'chat_api/tools#create'
end
