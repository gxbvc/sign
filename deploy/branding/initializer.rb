# frozen_string_literal: true

# Presentation only. Keep Docuseal.product_name and all attribution unchanged.
Rails.application.config.to_prepare do
  ActionController::Base.prepend_view_path('/opt/gxb-sign/views')
end
