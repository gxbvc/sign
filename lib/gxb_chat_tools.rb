# frozen_string_literal: true

# The five DocuSeal MCP operations (app/controllers/mcp/*_controller.rb) for GXB Chat (/chat_api/tools).
# Each call runs as the Chat user's own Sign user with DocuSeal's normal authorization (Ability, accessible_by,
# the user's account). It reuses the upstream schemas and logic. It does not use DocuSeal's /mcp endpoint, its
# MCP setting, or MCP tokens.
module GxbChatTools
  NotFound = Class.new(StandardError)
  Invalid = Class.new(StandardError)

  TOOLS = {
    'search_templates' => 'Mcp::SearchTemplatesController',
    'load_template' => 'Mcp::LoadTemplateController',
    'create_template' => 'Mcp::CreateTemplateController',
    'send_documents' => 'Mcp::SendDocumentsController',
    'search_documents' => 'Mcp::SearchDocumentsController'
  }.freeze

  SEND_WARNING = 'Sends signature request emails to real people. Cannot be undone.'

  DESCRIPTIONS = {
    'create_template' => 'Create a document template. Provide a public https URL of a PDF file to upload, or only ' \
                         'a name to create an empty template and receive an edit URL where the file can be ' \
                         'uploaded in the browser. Signature fields are placed in the browser editor.',
    'send_documents' => "#{SEND_WARNING} Sends a document template for signing to the listed submitters. Each " \
                        'submitter needs an email address and gets a signing link by email right away. Call ' \
                        'load_template first to get the role names.'
  }.freeze

  PDF_CONTENT_TYPE = 'application/pdf'

  module_function

  def tool?(name)
    TOOLS.key?(name)
  end

  def definitions
    TOOLS.map do |name, controller|
      schema = controller.constantize::SCHEMA

      {
        name:,
        title: schema[:title],
        description: DESCRIPTIONS.fetch(name, schema[:description]),
        parameters: parameters(name, schema[:inputSchema]),
        requires_confirmation: name == 'send_documents',
        # A bound tool never takes Chat's "always allow" shortcut, so every send waits for approval.
        confirmation_binding: ('template_id' if name == 'send_documents'),
        annotations: schema[:annotations]
      }.compact
    end
  end

  def parameters(name, schema)
    schema = schema.deep_dup

    case name
    when 'create_template'
      schema[:properties][:url] = { type: 'string', description: 'Optional public https URL of a PDF file. If ' \
                                                                 'omitted, an empty template is created.' }
    when 'send_documents'
      schema[:properties][:submitters][:items][:required] = %w[email]
    end

    schema
  end

  def call(name, user:, arguments:)
    raise NotFound unless tool?(name)
    raise Invalid, 'arguments must be an object' unless arguments.is_a?(Hash)

    send(name, user, Ability.new(user), arguments.deep_stringify_keys)
  end

  def search_templates(user, ability, args)
    raise NotFound unless ability.can?(:read, Template)

    templates = Templates.search(user, Template.accessible_by(ability).active, string!(args, 'q', required: true))
    templates = templates.order(id: :desc).limit(limit(args))

    { templates: templates.map { |t| { id: t.id, name: t.name } } }
  end

  def load_template(_user, ability, args)
    template = find_template(ability, args)

    submitters_index = template.submitters.index_by { |s| s['uuid'] }

    fields = template.fields.filter_map do |field|
      next if field['name'].blank?

      { name: field['name'], type: field['type'], role: submitters_index[field['submitter_uuid']]&.dig('name') }
    end

    { id: template.id, name: template.name, roles: template.submitters.pluck('name'), fields: }
  end

  def create_template(user, ability, args)
    name = string!(args, 'name', required: true).strip
    raise Invalid, 'name must not be blank' if name.blank?

    url = string!(args, 'url').presence
    file = download_pdf(url) if url

    account = user.account
    template = Template.new(account:, author: user, folder: account.default_template_folder, source: :mcp,
                            name:, fields: [], schema: [])

    raise NotFound unless ability.can?(:create, template)

    Templates.maybe_assign_access(template)

    template.save!
    attach_pdf!(template, file) if file

    WebhookUrls.enqueue_events(template, 'template.created')
    SearchEntries.enqueue_reindex(template)

    { id: template.id, name: template.name, edit_url: url_helpers.edit_template_url(template, **url_options) }
  rescue Templates::CreateAttachments::PdfEncrypted
    raise Invalid, 'The PDF is encrypted'
  rescue Templates::CreateAttachments::InvalidFileType
    raise Invalid, 'Only PDF files are supported'
  ensure
    file&.tempfile&.close!
  end

  # No transaction: PDF processing is slow, and a held SQLite write lock would block signers meanwhile.
  # A failure after the save removes the half-made template instead.
  def attach_pdf!(template, file)
    documents, = Templates::CreateAttachments.call(template, { files: [file] }, extract_fields: true)
    schema = documents.map { |doc| { attachment_uuid: doc.uuid, name: doc.filename.base } }

    if template.fields.blank?
      template.fields = Templates::ProcessDocument.normalize_attachment_fields(template,
                                                                               documents)
    end

    template.update!(schema:)
  rescue StandardError
    template.destroy!
    raise
  end

  def send_documents(user, ability, args)
    template = find_template(ability, args)
    submitters = submitters!(args)

    raise Invalid, 'Template has been archived' if template.archived_at?
    raise NotFound unless ability.can?(:create, Submission.new(template:, account_id: user.account_id))
    raise Invalid, 'Template has no fields' if template.fields.blank?

    check_roles!(template, submitters)

    submissions = Submissions.create_from_submitters(
      template:,
      user:,
      source: :mcp,
      submitters_order: template.preferences['submitters_order'].presence || 'random',
      submissions_attrs: { submitters: },
      params: { 'send_email' => true, 'submitters' => submitters }
    )

    raise Invalid, 'No valid submitters provided' if submissions.blank?

    WebhookUrls.enqueue_events(submissions, 'submission.created')
    Submissions.send_signature_requests(submissions)
    SearchEntries.enqueue_reindex(submissions)

    submission = submissions.first

    { id: submission.id, status: 'pending',
      submitters: submission.submitters.map { |s| { email: s.email, name: s.name, status: s.status } } }
  rescue Submissions::CreateFromSubmitters::BaseError => e
    raise Invalid, e.message
  end

  # Real emails go out, so refuse what upstream would quietly guess: an unknown role goes to the signer at the
  # same position, and submitters past the last role are skipped.
  def check_roles!(template, submitters)
    roles = template.submitters.pluck('name')
    unknown = submitters.filter_map { |s| s['role'] }.reject { |role| roles.any? { |r| r.to_s.casecmp?(role) } }
    raise Invalid, "Unknown role #{unknown.first.inspect}. Roles: #{roles.join(', ')}" if unknown.any?
    return if submitters.size <= roles.size

    raise Invalid, "Template has #{roles.size} role(s) (#{roles.join(', ')}), got #{submitters.size} submitters"
  end

  def search_documents(user, ability, args)
    raise NotFound unless ability.can?(:read, Submission)

    submissions = Submissions.search(user, Submission.accessible_by(ability).active,
                                     string!(args, 'q', required: true), search_template: true)
    submissions = submissions.preload(:submitters, :template).order(id: :desc).limit(limit(args))

    data = submissions.map do |submission|
      {
        id: submission.id,
        template_name: submission.template&.name,
        status: Submissions::SerializeForApi.build_status(submission, submission.submitters),
        submitters: submission.submitters.map do |s|
          { email: s.email, name: s.name, phone: s.phone, status: s.status }
        end,
        documents_url: url_helpers.submission_url(submission.id, **url_options)
      }
    end

    { submissions: data }
  end

  # A template in another account and a template that does not exist get the same answer.
  def find_template(ability, args)
    template = Template.accessible_by(ability).find_by(id: integer!(args, 'template_id'))
    raise NotFound if template.nil? || !ability.can?(:read, template)

    template
  end

  def download_pdf(url)
    body, filename = GxbSafeDownload.fetch(url)

    tempfile = Tempfile.new('gxb-chat-template')
    tempfile.binmode
    tempfile.write(body)
    tempfile.rewind

    type = Marcel::MimeType.for(tempfile)
    unless type == PDF_CONTENT_TYPE
      tempfile.close!
      raise Invalid, 'Only PDF files are supported'
    end

    ActionDispatch::Http::UploadedFile.new(tempfile:, filename:, type:)
  rescue GxbSafeDownload::Refused => e
    raise Invalid, e.message
  end

  def submitters!(args)
    list = args['submitters']
    raise Invalid, 'submitters must be a non-empty array' unless list.is_a?(Array) && list.present?

    list.map do |submitter|
      raise Invalid, 'each submitter must be an object' unless submitter.is_a?(Hash)

      attrs = %w[email name role phone].index_with { |key| string!(submitter, key) }.compact_blank
      raise Invalid, 'each submitter needs an email' if attrs['email'].blank?

      fields = submitter['fields'].nil? ? [] : submitter['fields']
      raise Invalid, 'fields must be an array' unless fields.is_a?(Array)

      fields = fields.filter_map do |field|
        raise Invalid, 'each field must be an object' unless field.is_a?(Hash)
        next if field['name'].blank?

        { 'name' => string!(field, 'name'), 'default_value' => field['value'], 'readonly' => true }
      end

      attrs['fields'] = fields if fields.present?

      attrs.with_indifferent_access
    end
  end

  def string!(args, key, required: false)
    value = args[key]
    raise Invalid, "#{key} is required" if value.nil? && required
    raise Invalid, "#{key} must be a string" unless value.nil? || value.is_a?(String)

    value
  end

  def integer!(args, key)
    value = args[key]
    return value if value.is_a?(Integer)
    return value.to_i if value.is_a?(String) && value.match?(/\A\d+\z/)

    raise Invalid, "#{key} must be an integer"
  end

  def limit(args)
    value = args['limit'].nil? ? 10 : integer!(args, 'limit')
    value = 10 if value <= 0

    [value, 100].min
  end

  def url_helpers
    Rails.application.routes.url_helpers
  end

  def url_options
    Docuseal.default_url_options
  end
end
