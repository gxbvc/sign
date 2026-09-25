# frozen_string_literal: true

# GXB Chat host API (ChatApi::ToolsController, GxbChatTools). Chat lists and calls these as sign__<name>.
describe 'Chat API tools' do
  let(:key) { 'test-chat-api-key' }
  let(:account) { create(:account) }
  let!(:user) { create(:user, account:, email: 'staff@gxb.vc') }
  let(:other_account) { create(:account) }
  let(:other_user) { create(:user, account: other_account, email: 'other@example.com') }
  let(:tool_names) { %w[search_templates load_template create_template send_documents search_documents] }
  let(:pdf) { Rails.root.join('spec/fixtures/sample-document.pdf').binread }

  around do |example|
    previous = ENV.fetch('CHAT_API_KEY', nil)
    ENV['CHAT_API_KEY'] = key
    example.run
  ensure
    ENV['CHAT_API_KEY'] = previous
  end

  def chat_headers(email: user.email, uid: nil, bearer: key)
    { 'Authorization' => "Bearer #{bearer}", 'X-Auth-UID' => uid.to_s, 'X-Auth-Email' => email.to_s }
  end

  def call_tool(tool, arguments, headers: chat_headers)
    post '/chat_api/tools', params: { tool:, arguments: }, headers:, as: :json
  end

  describe 'authentication' do
    it 'is 401 without the key, with a wrong key, and when CHAT_API_KEY is blank' do
      get '/chat_api/tools', headers: chat_headers.except('Authorization')
      expect(response).to have_http_status(:unauthorized)

      get '/chat_api/tools', headers: chat_headers(bearer: 'wrong')
      expect(response).to have_http_status(:unauthorized)

      ENV['CHAT_API_KEY'] = ''
      get '/chat_api/tools', headers: chat_headers(bearer: '')
      expect(response).to have_http_status(:unauthorized)
      get '/chat_api/tools', headers: chat_headers
      expect(response).to have_http_status(:unauthorized)

      call_tool('search_templates', { q: '' }, headers: chat_headers(bearer: ''))
      expect(response).to have_http_status(:unauthorized)
    end

    it 'is 403 without identity headers, for gxbot, and for unknown users' do
      get '/chat_api/tools', headers: chat_headers(email: '')
      expect(response).to have_http_status(:forbidden)

      get '/chat_api/tools', headers: chat_headers(email: 'GXBot@gxb.vc')
      expect(response).to have_http_status(:forbidden)

      get '/chat_api/tools', headers: chat_headers(email: 'nobody@gxb.vc')
      expect(response).to have_http_status(:forbidden)
    end

    it 'is 403 when the resolved user is gxbot' do
      create(:user, account:, email: 'gxbot@gxb.vc', auth_uid: 'gxbot-uid')

      get '/chat_api/tools', headers: chat_headers(email: '', uid: 'gxbot-uid')
      expect(response).to have_http_status(:forbidden)
    end

    it 'is 403 for an archived user' do
      user.update!(archived_at: Time.current)

      get '/chat_api/tools', headers: chat_headers
      expect(response).to have_http_status(:forbidden)
    end

    it 'is 403 when the uid and the email point at different users' do
      create(:user, account:, email: 'second@gxb.vc', auth_uid: 'second-uid')

      get '/chat_api/tools', headers: chat_headers(uid: 'second-uid')
      expect(response).to have_http_status(:forbidden)
    end

    it 'falls back to email (case-insensitive) and backfills a blank auth_uid' do
      get '/chat_api/tools', headers: chat_headers(email: 'Staff@GXB.vc', uid: 'staff-uid')

      expect(response).to have_http_status(:ok)
      expect(user.reload.auth_uid).to eq('staff-uid')

      get '/chat_api/tools', headers: chat_headers(email: '', uid: 'staff-uid')
      expect(response).to have_http_status(:ok)
    end

    it 'is 403 and never rebinds a user bound to another subject' do
      user.update!(auth_uid: 'original-uid')

      get '/chat_api/tools', headers: chat_headers(uid: 'new-uid')

      expect(response).to have_http_status(:forbidden)
      expect(user.reload.auth_uid).to eq('original-uid')
    end

    it 'does not create a session or set a cookie' do
      get '/chat_api/tools', headers: chat_headers(uid: 'staff-uid')
      expect(response).to have_http_status(:ok)
      expect(response.headers['Set-Cookie']).to be_blank

      call_tool('search_templates', { q: '' }, headers: chat_headers(uid: 'staff-uid'))
      expect(response).to have_http_status(:ok)
      expect(response.headers['Set-Cookie']).to be_blank

      get '/templates'
      expect(response).to have_http_status(:found)
    end
  end

  describe 'GET /chat_api/tools' do
    it 'lists exactly the five tools with schemas, and marks send_documents as destructive' do
      get '/chat_api/tools', headers: chat_headers

      expect(response).to have_http_status(:ok)
      tools = response.parsed_body.fetch('tools').index_by { |tool| tool.fetch('name') }
      expect(tools.keys).to match_array(tool_names)

      tools.each_value do |tool|
        expect(tool.keys).to include('title', 'description', 'parameters', 'requires_confirmation', 'annotations')
        expect(tool.dig('parameters', 'type')).to eq('object')
      end

      send_documents = tools.fetch('send_documents')
      expect(send_documents['requires_confirmation']).to be(true)
      expect(send_documents['confirmation_binding']).to eq('template_id')
      expect(send_documents['annotations']).to include('readOnlyHint' => false, 'destructiveHint' => true)
      expect(send_documents['description']).to start_with('Sends signature request emails to real people. ' \
                                                          'Cannot be undone.')
      expect(send_documents.dig('parameters', 'required')).to eq(%w[template_id submitters])

      expect(tools.fetch('create_template')['annotations']).to include('readOnlyHint' => false,
                                                                       'destructiveHint' => false)
      expect(tools.fetch('create_template')['requires_confirmation']).to be(false)
      expect(tools.except('send_documents').values.pluck('confirmation_binding').compact).to be_empty

      %w[search_templates load_template search_documents].each do |name|
        expect(tools.fetch(name)['annotations']).to include('readOnlyHint' => true)
        expect(tools.fetch(name)['requires_confirmation']).to be(false)
      end
    end
  end

  describe 'POST /chat_api/tools' do
    let!(:template) { create(:template, account:, author: user, name: 'Advisory Agreement') }
    let!(:other_template) { create(:template, account: other_account, author: other_user, name: 'Advisory Secret') }

    it 'is 404 for an unknown tool and 422 for bad arguments' do
      call_tool('delete_everything', {})
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq('error' => 'Unknown tool')

      call_tool('load_template', { template_id: 'abc' })
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('template_id')

      call_tool('search_templates', {})
      expect(response).to have_http_status(:unprocessable_content)

      post '/chat_api/tools', params: { tool: 'search_templates', arguments: [1] }, headers: chat_headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'searches only the user templates' do
      call_tool('search_templates', { q: 'Advisory' })

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('templates' => [{ 'id' => template.id, 'name' => 'Advisory Agreement' }])
    end

    it 'loads a template and hides templates from other accounts' do
      call_tool('load_template', { template_id: template.id })

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body).to include('id' => template.id, 'name' => 'Advisory Agreement', 'roles' => ['First Party'])
      expect(body['fields']).to include('name' => 'First Name', 'type' => 'text', 'role' => 'First Party')

      call_tool('load_template', { template_id: other_template.id })
      expect(response).to have_http_status(:not_found)
      hidden = response.parsed_body

      call_tool('load_template', { template_id: 999_999_999 })
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq(hidden)
    end

    it 'searches only the user submissions' do
      mine = create(:submission, :with_submitters, template:, created_by_user: user)
      create(:submission, :with_submitters, template: other_template, created_by_user: other_user)

      call_tool('search_documents', { q: 'Advisory' })

      expect(response).to have_http_status(:ok)
      submissions = response.parsed_body.fetch('submissions')
      expect(submissions.pluck('id')).to eq([mine.id])
      expect(submissions.first).to include('template_name' => 'Advisory Agreement')
      expect(submissions.first['documents_url']).to end_with("/submissions/#{mine.id}")
    end

    describe 'send_documents' do
      before do
        ActionMailer::Base.deliveries.clear
        SendSubmitterInvitationEmailJob.clear
      end

      it 'creates the submission in the user account and emails through the test mailer only' do
        expect(ActionMailer::Base.delivery_method).to eq(:test)

        expect do
          call_tool('send_documents', { template_id: template.id,
                                        submitters: [{ email: 'signer@example.com', name: 'Signer',
                                                       role: 'First Party',
                                                       fields: [{ name: 'First Name', value: 'Sam' }] }] })
        end.to change(Submission, :count).by(1)

        expect(response).to have_http_status(:ok)
        submission = Submission.find(response.parsed_body.fetch('id'))
        expect(response.parsed_body['status']).to eq('pending')
        expect(submission.account_id).to eq(account.id)
        expect(submission.created_by_user_id).to eq(user.id)
        expect(submission.submitters.pluck(:email)).to eq(['signer@example.com'])
        expect(response.parsed_body['submitters']).to eq([{ 'email' => 'signer@example.com', 'name' => 'Signer',
                                                            'status' => submission.submitters.first.status }])

        expect(SendSubmitterInvitationEmailJob.jobs.size).to eq(1)
        SendSubmitterInvitationEmailJob.drain

        expect(ActionMailer::Base.deliveries.flat_map(&:to)).to eq(['signer@example.com'])
      end

      it 'cannot send another account template and refuses bad submitters' do
        expect do
          call_tool('send_documents', { template_id: other_template.id, submitters: [{ email: 'x@example.com' }] })
        end.not_to change(Submission, :count)
        expect(response).to have_http_status(:not_found)

        call_tool('send_documents', { template_id: template.id, submitters: [] })
        expect(response).to have_http_status(:unprocessable_content)

        call_tool('send_documents', { template_id: template.id, submitters: [{ name: 'No email' }] })
        expect(response).to have_http_status(:unprocessable_content)

        call_tool('send_documents', { template_id: template.id,
                                      submitters: [{ email: 'x@example.com', role: 'Missing Role' }] })
        expect(response).to have_http_status(:unprocessable_content)

        too_many = Array.new(template.submitters.size + 1) { |i| { email: "extra#{i}@example.com" } }
        expect do
          call_tool('send_documents', { template_id: template.id, submitters: too_many })
        end.not_to change(Submission, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to include('role(s)')

        expect(SendSubmitterInvitationEmailJob.jobs).to be_empty
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'answers malformed JSON and unexpected errors with JSON' do
      post '/chat_api/tools', params: '{"tool":', headers: chat_headers.merge('Content-Type' => 'application/json')
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('error' => 'Invalid JSON')

      allow(GxbChatTools).to receive(:call).and_raise(RuntimeError, 'boom')
      call_tool('search_templates', { q: 'x' })
      expect(response).to have_http_status(:internal_server_error)
      expect(response.parsed_body).to eq('error' => 'Tool failed')
    end

    describe 'create_template' do
      let(:public_ip) { '93.184.216.34' }

      before { allow(GxbSafeDownload).to receive(:resolve).and_return([public_ip]) }

      it 'removes the template when processing the downloaded PDF fails' do
        stub_request(:get, 'https://files.example.com/broken.pdf')
          .to_return(status: 200, body: pdf)
        allow(Templates::CreateAttachments).to receive(:call).and_raise(RuntimeError, 'pdf failure')

        expect do
          call_tool('create_template', { name: 'Broken', url: 'https://files.example.com/broken.pdf' })
        end.not_to change(Template, :count)
        expect(response).to have_http_status(:internal_server_error)
      end

      it 'creates an empty template with an edit URL' do
        call_tool('create_template', { name: 'Office License Amendment' })

        expect(response).to have_http_status(:ok)
        created = Template.find(response.parsed_body.fetch('id'))
        expect(created).to have_attributes(account_id: account.id, author_id: user.id,
                                           name: 'Office License Amendment')
        expect(response.parsed_body['edit_url']).to end_with("/templates/#{created.id}/edit")
      end

      it 'creates a template from a public https PDF URL' do
        stub_request(:get, 'https://files.example.com/docs/amendment.pdf')
          .to_return(status: 200, body: pdf, headers: { 'Content-Type' => 'application/pdf' })

        call_tool('create_template', { name: 'Amendment', url: 'https://files.example.com/docs/amendment.pdf' })

        expect(response).to have_http_status(:ok)
        created = Template.find(response.parsed_body.fetch('id'))
        expect(created.account_id).to eq(account.id)
        expect(created.schema.size).to eq(1)
        expect(created.documents.size).to eq(1)
      end

      it 'follows a redirect only to another public https URL' do
        stub_request(:get, 'https://files.example.com/a.pdf')
          .to_return(status: 302, headers: { 'Location' => 'http://files.example.com/b.pdf' })

        expect do
          call_tool('create_template', { name: 'Redirected', url: 'https://files.example.com/a.pdf' })
        end.not_to change(Template, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('Only https URLs are allowed')
      end

      it 'refuses non-https, private, and loopback URLs without a request' do
        {
          'http://files.example.com/a.pdf' => nil,
          'ftp://files.example.com/a.pdf' => nil,
          'https://files.example.com:8443/a.pdf' => nil,
          'https://user:pass@files.example.com/a.pdf' => nil,
          'https://localhost/a.pdf' => '127.0.0.1',
          'https://internal.example.com/a.pdf' => '10.1.2.3',
          'https://metadata.example.com/a.pdf' => '169.254.169.254',
          'https://v6.example.com/a.pdf' => '::1',
          'https://mapped.example.com/a.pdf' => '::ffff:192.168.1.1',
          'https://mixed.example.com/a.pdf' => [public_ip, '172.16.0.5']
        }.each do |url, addresses|
          allow(GxbSafeDownload).to receive(:resolve).and_return(Array(addresses))

          expect do
            call_tool('create_template', { name: 'Refused', url: })
          end.not_to change(Template, :count)

          expect(response).to have_http_status(:unprocessable_content), url
        end

        expect(WebMock).not_to have_requested(:any, /.*/)
      end

      it 'refuses files that are too large or not a PDF' do
        stub_const('GxbSafeDownload::MAX_BYTES', 10)
        stub_request(:get, 'https://files.example.com/big.pdf').to_return(status: 200, body: pdf)

        call_tool('create_template', { name: 'Big', url: 'https://files.example.com/big.pdf' })
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('File is too large')
      end

      it 'refuses a file that is not a PDF' do
        stub_request(:get, 'https://files.example.com/a.docx')
          .to_return(status: 200, body: Rails.root.join('spec/fixtures/fieldtags.docx').binread)

        expect do
          call_tool('create_template', { name: 'Docx', url: 'https://files.example.com/a.docx' })
        end.not_to change(Template, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('Only PDF files are supported')
      end
    end
  end
end
