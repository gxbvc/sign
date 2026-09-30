# frozen_string_literal: true

# Field guard (lib/gxb_field_guard.rb): every template or submission save, from the editor, the REST API, PDF tags,
# DocuSeal MCP, or GXB Chat, goes through the same model checks, so a field the signing form cannot show or a signer
# cannot fill is refused when it is written, not found when someone tries to sign.
Rails.application.config.to_prepare do
  Template.include(GxbTemplateFields)
  Submission.include(GxbSubmissionFields)

  # Upstream lets RecordInvalid become a 500. The guard must tell the caller which field is wrong.
  Api::ApiBaseController.rescue_from(ActiveRecord::RecordInvalid) do |e|
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_content
  end

  Mcp::McpBaseController.rescue_from(ActiveRecord::RecordInvalid) do |e|
    render_tool_error(e.record.errors.full_messages.to_sentence)
  end
end
