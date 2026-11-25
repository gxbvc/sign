# frozen_string_literal: true

# The GXB API operations (manifest: lib/gxb_api_manifest.rb). Each runs as the person's own Sign user with
# DocuSeal's normal authorization (Ability, accessible_by, the user's account), like GxbChatTools, whose checks
# and send path they reuse. A read for a person with no Sign account yet sees an empty account and creates
# nothing (GxbApiAccounts makes the account only on a write operation).
#
# Arguments come as the gateway sends them (service contract 3.5): filter, sort, fields and submitters in the
# query are compact JSON text.
module GxbApiOperations
  NotFound = GxbChatTools::NotFound
  Invalid = GxbChatTools::Invalid
  Conflict = Class.new(StandardError)

  DEFAULT_LIMIT = 25
  MAX_LIMIT = 100
  MAX_OFFSET = 100_000
  RANGE_OPS = %w[gt gte lt lte].freeze
  TEMPLATE_FILTERS = { 'folder' => %w[eq], 'author_email' => %w[eq], 'created_at' => RANGE_OPS }.freeze
  DOCUMENT_FILTERS = { 'status' => %w[eq], 'template_id' => %w[eq], 'author_email' => %w[eq],
                       'created_at' => RANGE_OPS, 'completed_at' => RANGE_OPS }.freeze
  STATUSES = %w[pending sent opened partially_completed completed declined expired].freeze
  TEMPLATE_SORTS = %w[created_at -created_at name -name].freeze
  DOCUMENT_SORTS = %w[created_at -created_at].freeze

  module_function

  # sign.template.list
  def template_list(user, params)
    args = list_args(params, TEMPLATE_FILTERS, TEMPLATE_SORTS, GxbApiManifest::TEMPLATE_FIELDS)
    return empty_page if user.nil?

    ability = Ability.new(user)
    raise NotFound unless ability.can?(:read, Template)

    scope = Template.accessible_by(ability).active
    scope = Templates.search(user, scope, args[:q]) if args[:q].present?
    scope = args[:filter].reduce(scope) { |rel, cond| template_condition(rel, cond, user) }

    rows, meta = page(scope.preload(:folder, :author), Template, args)

    { data: rows.map { |t| pick(template_record(t), args[:fields]) }, meta: }
  end

  # sign.template.get
  def template_get(user, params)
    raise NotFound if user.nil?

    template = GxbChatTools.find_template(Ability.new(user), { 'template_id' => params['template_id'] })
    roles = template.submitters.index_by { |s| s['uuid'] }

    fields = template.fields.filter_map do |field|
      next if field['name'].blank?

      { name: field['name'], type: field['type'], role: roles[field['submitter_uuid']]&.dig('name'),
        required: field['required'] == true }
    end

    { data: { id: template.id, name: template.name, roles: template.submitters.pluck('name'), fields:,
              version: template_version(template), edit_url: edit_url(template) } }
  end

  # sign.template.create
  def template_create(user, body)
    only!(body, %w[name url])

    result = GxbChatTools.create_template(user, Ability.new(user), body)
    template = Template.find(result[:id])

    { data: { id: template.id, name: template.name, version: template_version(template),
              edit_url: result[:edit_url] } }
  end

  # sign.document.list
  def document_list(user, params)
    args = list_args(params, DOCUMENT_FILTERS, DOCUMENT_SORTS, GxbApiManifest::DOCUMENT_FIELDS)
    return empty_page if user.nil?

    ability = Ability.new(user)
    raise NotFound unless ability.can?(:read, Submission)

    scope = Submission.accessible_by(ability).active
    scope = Submissions.search(user, scope, args[:q], search_template: true) if args[:q].present?
    scope = args[:filter].reduce(scope) { |rel, cond| document_condition(rel, cond, user) }

    rows, meta = page(scope.preload(:submitters, :template), Submission, args)

    { data: rows.map { |s| pick(document_record(s), args[:fields]) }, meta: }
  end

  # sign.signature_request.preview: every check of a send, and nothing saved or sent.
  def signature_request_preview(user, params)
    raise NotFound if user.nil?

    template, submitters = checked_send(user, params['template_id'], json_param(params, 'submitters', Array))

    { data: { template_id: template.id, template_name: template.name, template_version: template_version(template),
              submitters: preview_submitters(template, submitters), emails_to: submitters.pluck('email').uniq,
              confirmation: confirmation(user, template, submitters) } }
  end

  # sign.signature_request.create: needs the preview's confirmation for the same template version and the same
  # submitters. Then the GxbChatTools send path (DocuSeal's own submission and email jobs).
  def signature_request_create(user, body)
    only!(body, %w[template_id submitters confirmation])

    template, submitters = checked_send(user, body['template_id'], body['submitters'])
    given = body['confirmation']
    expected = confirmation(user, template, submitters)
    unless given.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(given, expected)
      raise Conflict, 'The template or the submitters changed since the preview, or the confirmation is wrong. ' \
                      'Run sign.signature_request.preview again.'
    end

    result = GxbChatTools.send_documents(user, Ability.new(user), body.slice('template_id', 'submitters'))

    { data: result.merge(template_id: template.id) }
  end

  def checked_send(user, template_id, raw_submitters)
    ability = Ability.new(user)
    template = GxbChatTools.find_template(ability, { 'template_id' => template_id })
    submitters = GxbChatTools.submitters!({ 'submitters' => raw_submitters })
    submitters.each { |s| s['email'] = s['email'].to_s.strip.downcase }

    raise Invalid, 'Template has been archived' if template.archived_at?
    raise NotFound unless ability.can?(:create, Submission.new(template:, account_id: user.account_id))
    raise Invalid, 'Template has no fields' if template.fields.blank?

    problems = GxbFieldGuard.signable_problems(template.fields, template.submitters)
    raise Invalid, problems.first if problems.any?

    GxbChatTools.check_roles!(template, submitters)

    [template, submitters]
  end

  def preview_submitters(template, submitters)
    roles = template.submitters.pluck('name')

    submitters.each_with_index.map do |s, index|
      role = s['role'].present? ? roles.find { |r| r.to_s.casecmp?(s['role']) } : roles[index]

      { email: s['email'], name: s['name'], phone: s['phone'], role:, status: 'not_sent' }
    end
  end

  def confirmation(user, template, submitters)
    data = [user.id, template.id, template_version(template), submitters.map(&:to_h)]

    OpenSSL::HMAC.hexdigest('SHA256', confirmation_key, GxbApiIdempotency.canonical(data))[0, 32]
  end

  def confirmation_key
    Rails.application.key_generator.generate_key('gxb-api signature request confirmation', 32)
  end

  def template_version(template)
    Digest::SHA256.hexdigest(GxbApiIdempotency.canonical([template.name, template.fields, template.submitters,
                                                          template.schema]))[0, 16]
  end

  def template_record(template)
    { id: template.id, name: template.name, folder: template.folder&.name, author_email: template.author&.email,
      roles: template.submitters.pluck('name'), version: template_version(template),
      created_at: template.created_at&.iso8601, updated_at: template.updated_at&.iso8601 }
  end

  def document_record(submission)
    submitters = submission.submitters.sort_by(&:id)
    roles = (submission.template_submitters.presence || submission.template&.submitters).to_a.index_by do |s|
      s['uuid']
    end

    { id: submission.id, template_id: submission.template_id, template_name: submission.template&.name,
      status: document_status(submission, submitters),
      submitters: submitters.map do |s|
        { email: s.email, name: s.name, phone: s.phone, role: roles[s.uuid]&.dig('name'), status: s.status }
      end,
      documents_url: Rails.application.routes.url_helpers.submission_url(submission.id,
                                                                         **Docuseal.default_url_options),
      created_at: submission.created_at&.iso8601, completed_at: submission.completed_at&.iso8601 }
  end

  def document_status(submission, submitters)
    return 'completed' if submission.completed_at?

    Submissions::SerializeForApi.build_status(submission, submitters)
  end

  def edit_url(template)
    Rails.application.routes.url_helpers.edit_template_url(template, **Docuseal.default_url_options)
  end

  # Filters. Only the listed fields and ops; values are bound, never written into SQL text.
  def template_condition(scope, cond, user)
    table = Template.arel_table

    case cond['field']
    when 'folder' then scope.where(folder_id: TemplateFolder.where(account_id: user.account_id,
                                                                   name: string_value(cond)).select(:id))
    when 'author_email' then scope.where(author_id: author_id(user, cond))
    when 'created_at' then scope.where(range(table[:created_at], cond))
    end
  end

  def document_condition(scope, cond, user)
    table = Submission.arel_table

    case cond['field']
    when 'status'
      status = string_value(cond)
      raise Invalid, "status must be one of: #{STATUSES.join(', ')}" unless STATUSES.include?(status)

      Submissions::Filter.filter_by_status(scope, { status: })
    when 'template_id' then scope.where(template_id: integer_value(cond))
    when 'author_email' then scope.where(created_by_user_id: author_id(user, cond))
    when 'created_at' then scope.where(range(table[:created_at], cond))
    when 'completed_at' then scope.where(range(table[:completed_at], cond))
    end
  end

  def author_id(user, cond)
    value = string_value(cond).strip.downcase
    return user.id if value == 'me'

    user.account.users.find_by('LOWER(email) = ?', value)&.id || -1
  end

  def range(column, cond)
    time = time_value(cond)

    case cond['op']
    when 'gt' then column.gt(time)
    when 'gte' then column.gteq(time)
    when 'lt' then column.lt(time)
    when 'lte' then column.lteq(time)
    end
  end

  def string_value(cond)
    raise Invalid, "#{cond['field']} needs a string value" unless cond['value'].is_a?(String)

    cond['value']
  end

  def integer_value(cond)
    value = cond['value']
    return value if value.is_a?(Integer)
    return value.to_i if value.is_a?(String) && value.match?(/\A\d{1,18}\z/)

    raise Invalid, "#{cond['field']} needs an integer value"
  end

  def time_value(cond)
    value = string_value(cond)

    Time.iso8601(value)
  rescue ArgumentError
    begin
      Date.iso8601(value).in_time_zone('UTC')
    rescue Date::Error
      raise Invalid, "#{cond['field']} needs an ISO 8601 time"
    end
  end

  # Arguments.
  def list_args(params, filters, sorts, fields)
    q = params['q']
    raise Invalid, 'q must be a string' unless q.nil? || q.is_a?(String)

    { q:, filter: filter_arg(params, filters), sort: sort_arg(params, sorts),
      fields: fields_arg(params, fields), limit: limit_arg(params), offset: cursor_offset(params['cursor']) }
  end

  def filter_arg(params, allowed)
    filter = json_param(params, 'filter', Hash)
    return [] if filter.nil?

    conditions = filter['and']
    raise Invalid, 'filter must be {"and": [...]}' unless filter.keys == ['and'] && conditions.is_a?(Array)
    raise Invalid, 'filter takes at most 10 conditions' if conditions.size > 10

    conditions.each do |cond|
      shaped = cond.is_a?(Hash) && cond.keys.sort == %w[field op value]
      raise Invalid, 'each condition is {"field", "op", "value"}' unless shaped
      raise Invalid, "unknown filter field #{cond['field'].inspect}" unless allowed.key?(cond['field'])
      raise Invalid, "#{cond['field']} does not take op #{cond['op'].inspect}" unless
        allowed[cond['field']].include?(cond['op'])
    end
  end

  def sort_arg(params, allowed)
    sort = json_param(params, 'sort', Array) || ['-created_at']
    raise Invalid, 'sort takes one field' if sort.size > 1
    raise Invalid, "sort must be one of: #{allowed.join(', ')}" unless sort.all? { |s| allowed.include?(s) }

    sort.first || '-created_at'
  end

  def fields_arg(params, allowed)
    fields = json_param(params, 'fields', Array)
    return if fields.nil?
    raise Invalid, "fields must be from: #{allowed.join(', ')}" unless fields.all? { |f| allowed.include?(f) }

    fields
  end

  def limit_arg(params)
    value = params['limit']
    return DEFAULT_LIMIT if value.nil?
    raise Invalid, "limit must be an integer from 1 to #{MAX_LIMIT}" unless value.to_s.match?(/\A\d{1,3}\z/)

    value = value.to_i
    raise Invalid, "limit must be an integer from 1 to #{MAX_LIMIT}" unless value.between?(1, MAX_LIMIT)

    value
  end

  # A cursor is the offset of the next page. Pages are ordered with id as the last key, so they are stable.
  def cursor_offset(cursor)
    return 0 if cursor.nil?

    data = JSON.parse(Base64.urlsafe_decode64(cursor.to_s))
    offset = data.is_a?(Hash) ? data['o'] : nil
    raise ArgumentError unless offset.is_a?(Integer) && offset.between?(0, MAX_OFFSET)

    offset
  rescue ArgumentError, JSON::ParserError
    raise Invalid, 'cursor is not valid: use meta.next_cursor from the page before'
  end

  def json_param(params, name, type)
    value = params[name]
    return if value.nil?

    value = JSON.parse(value) if value.is_a?(String)
    raise Invalid, "#{name} must be a JSON #{type.name.downcase}" unless value.is_a?(type)

    value
  rescue JSON::ParserError
    raise Invalid, "#{name} must be a JSON #{type.name.downcase}"
  end

  def only!(body, allowed)
    raise Invalid, 'the body must be a JSON object' unless body.is_a?(Hash)

    extra = body.keys - allowed
    raise Invalid, "unknown argument #{extra.first.inspect}" if extra.any?
  end

  def page(scope, model, args)
    table = model.arel_table
    column, direction = args[:sort].start_with?('-') ? [args[:sort][1..], :desc] : [args[:sort], :asc]

    rows = scope.order(table[column].public_send(direction), table[:id].public_send(direction))
                .offset(args[:offset]).limit(args[:limit] + 1).to_a
    more = rows.size > args[:limit]
    next_offset = args[:offset] + args[:limit]
    next_cursor = Base64.urlsafe_encode64({ o: next_offset }.to_json, padding: false) if more

    [rows.first(args[:limit]), { next_cursor:, has_more: more }]
  end

  def empty_page
    { data: [], meta: { next_cursor: nil, has_more: false } }
  end

  def pick(record, fields)
    return record if fields.nil?

    record.slice(:id, *fields.map(&:to_sym))
  end
end
