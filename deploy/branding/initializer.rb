# frozen_string_literal: true

# Presentation only. The product name itself is set in lib/docuseal.rb.
Rails.application.config.to_prepare do
  ActionController::Base.prepend_view_path('/opt/gxb-sign/views')
end
