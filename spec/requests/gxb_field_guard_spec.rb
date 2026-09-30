# frozen_string_literal: true

# GxbFieldGuard through the REST API: the same model checks answer 422 with the field name instead of a 500.
describe 'GXB field guard API' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:) }
  let(:headers) { { 'x-auth-token': author.access_token.token, 'content-type' => 'application/json' } }
  let(:submitter_uuid) { template.submitters.first['uuid'] }

  def api_field(overrides = {})
    { 'uuid' => SecureRandom.uuid, 'submitter_uuid' => submitter_uuid, 'name' => 'Name', 'type' => 'text',
      'required' => true, 'preferences' => {}, 'areas' => [] }.merge(overrides)
  end

  def update_fields(fields)
    put "/api/templates/#{template.id}", params: { fields: }.to_json, headers:
  end

  it 'answers 422 with the field name and the allowed types for a type the form cannot show' do
    update_fields([api_field('name' => 'Stamp duty', 'type' => 'dropdown')])

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to include('"Stamp duty"', '"dropdown"', 'read-only date')
  end

  it 'stores a datenow field as a read-only date' do
    update_fields([api_field('name' => 'Date', 'type' => 'datenow')])

    expect(response).to have_http_status(:ok)
    expect(template.reload.fields.first).to include('type' => 'date', 'readonly' => true, 'default_value' => '{{date}}')
  end
end
