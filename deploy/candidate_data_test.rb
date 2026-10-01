# frozen_string_literal: true

# Run only in a disposable candidate on a temp copy of production data (deploy/candidate.rb mode B).
# Prints ids, names, statuses, path shapes, and counts only. Never secrets, slugs, or document contents.
abort 'Not a disposable data-copy check' unless ENV['SIGN_DATA_COPY_CHECK'] == 'true'
abort 'Migrations must be disabled for this check' unless ENV['RUN_MIGRATIONS'] == 'false'

BAILEY_TEMPLATE_ID = 2
BAILEY_NAME = 'GXB-Bailey Advisory Agreement v6 (2026-09-23)'
EXPECTED_SCHEMA = '20260819091500'

def applied_versions
  ActiveRecord::Base.connection.select_values('SELECT version FROM schema_migrations').map(&:to_s)
end

def schema_version
  applied_versions.max.to_s
end

def pending_migrations
  ActiveRecord::Base.connection_pool.migration_context.open.pending_migrations.map(&:version)
end

def new_session
  ActionDispatch::Integration::Session.new(Rails.application).tap { |session| session.host!('localhost') }
end

# Replaces the slug with :slug so the output shows only the shape.
def path_shape(location, slug)
  URI(location.to_s).path.sub(slug, ':slug')
end

phase = ARGV.fetch(0)
gxb_migrations = ARGV.fetch(1).split(',')

case phase
when 'before'
  workdir = ENV.fetch('WORKDIR')
  raise 'dump.rdb present; queued jobs could run' if File.exist?(File.join(workdir, 'dump.rdb'))

  upstream = applied_versions - gxb_migrations
  raise "Unexpected upstream schema: #{upstream.max}" unless upstream.max == EXPECTED_SCHEMA

  puts "INFO: schema_version=#{schema_version}"
  puts "INFO: upstream_migrations=#{upstream.size}"
  puts "INFO: gxb_migrations_applied=#{(applied_versions & gxb_migrations).join(',')}"
  puts "INFO: pending_migrations=#{pending_migrations.size}"
  puts "INFO: users=#{User.count} templates=#{Template.count} submissions=#{Submission.count} submitters=#{Submitter.count}"
  puts 'PASS: pre-boot read (no dump.rdb)'
when 'after'
  before = ARGV.fetch(2)
  upstream_before = Integer(ARGV.fetch(3))
  versions = applied_versions
  upstream = versions - gxb_migrations
  pending = pending_migrations
  puts "INFO: schema_version before=#{before} after=#{schema_version} pending=#{pending.size}"
  raise 'Upstream migrations changed by boot' unless upstream.size == upstream_before && upstream.max == EXPECTED_SCHEMA
  raise 'GXB migrations not all applied' unless (gxb_migrations - versions).empty?
  raise "Pending migrations: #{pending.join(',')}" unless pending.empty?
  raise 'Missing users.auth_uid' unless User.column_names.include?('auth_uid')

  puts "PASS: boot applied only GXB migrations #{gxb_migrations.join(',')}"

  template = Template.find(BAILEY_TEMPLATE_ID)
  puts "INFO: template id=#{template.id} name=#{template.name.inspect} archived=#{template.archived_at.present?}"
  raise 'Bailey template name changed' unless template.name == BAILEY_NAME

  submitters = Submitter.joins(:submission).where(submissions: { template_id: template.id }).order(:id)
  submitters.each do |submitter|
    puts "INFO: submitter id=#{submitter.id} submission_id=#{submitter.submission_id} status=#{submitter.status}"
  end
  raise "Expected 2 Bailey submitters, got #{submitters.size}" unless submitters.size == 2
  raise 'Bailey submitters not all completed' unless submitters.all? { |s| s.completed_at.present? }

  # Field guard on the copied data. A template that fails type_problems could not be saved again (even a rename), so
  # that stops the deploy. signable_problems only means a new send would be refused, so it is printed for review.
  raw_datenow = Template.all.sum { |t| t.fields.count { |f| f['type'] == 'datenow' } }
  puts "INFO: raw datenow fields in templates=#{raw_datenow} (the guard converts them on the next save)"
  Template.find_each do |t|
    problems = GxbFieldGuard.type_problems(GxbFieldGuard.normalize(t.fields))
    raise "Template #{t.id} fails the field guard: #{problems.join('; ')}" unless problems.empty?

    signable = GxbFieldGuard.signable_problems(GxbFieldGuard.normalize(t.fields), t.submitters)
    puts "WARN: template #{t.id} would be refused for sending: #{signable.join('; ')}" unless signable.empty?
  end
  puts "PASS: all #{Template.count} templates pass the field guard"

  session = new_session
  session.get('/setup')
  raise "Setup open on production copy: #{session.response.status}" unless session.response.redirect?

  session.get('/')
  html = Nokogiri::HTML(session.response.body)
  if session.response.status == 200
    raise 'Wrong page title' unless html.at_css('title').text.strip == 'GXB Sign'
    raise 'Missing DocuSeal credit' unless html.css('a').any? { |a| a.text == 'DocuSeal' && a['href'] == 'https://github.com/docusealco/docuseal' }
    raise 'Powered-by footer present' if html.text.match?(/powered by/i)
    raise 'Missing source' unless html.at_css('a[href="/gxb-sign/source.tar.gz"]')
  end
  puts "INFO: landing status=#{session.response.status}"

  # Signers never need a login: each Bailey link goes to its completed page, with no cookie.
  submitters.each do |submitter|
    signer = new_session
    signer.get("/s/#{submitter.slug}")
    first = [signer.response.status, path_shape(signer.response.location, submitter.slug)]
    raise "Signing link redirected to auth: #{first.inspect}" if signer.response.location.to_s.include?('auth.gxb.vc')
    raise "Signing link wanted a login: #{first.inspect}" if first.last.start_with?('/sign_in')
    raise "Signing link did not go to completed: #{first.inspect}" unless first == [302, '/s/:slug/completed']

    signer.get("/s/#{submitter.slug}/completed")
    raise "Completed page status #{signer.response.status}" unless signer.response.status == 200

    puts "INFO: submitter id=#{submitter.id} /s/:slug #{first.first} -> #{first.last} 200"
  end

  # Staff pages go to GXB (never followed; no egress). The old password fallback goes there too.
  staff = new_session
  staff.get('/templates')
  authorize = URI(staff.response.location.to_s)
  query = Rack::Utils.parse_query(authorize.query)
  raise "Staff page status #{staff.response.status}" unless staff.response.status == 302
  raise 'Staff page not sent to GXB' unless "#{authorize.host}#{authorize.path}" == 'auth.gxb.vc/oauth/authorize'
  raise 'Wrong GXB client or callback' unless query['client_id'] == 'sign' &&
                                              query['redirect_uri'] == 'http://localhost/auth/callback'
  staff.get('/sign_in?password=1')
  raise 'Old password fallback not sent to GXB' unless staff.response.location.to_s.start_with?('https://auth.gxb.vc/')
  raise 'Devise params authentication is on' unless Devise.params_authenticatable == false

  puts 'PASS: staff page and /sign_in?password=1 -> auth.gxb.vc/oauth/authorize (client_id=sign), password sign-in off'

  # Chat host API as Christian with the fake candidate key and his email only (no auth_uid header, so no
  # backfill write). Read-only: list the tools and search templates. Never create_template or send_documents.
  chat_headers = { 'Authorization' => "Bearer #{ENV.fetch('CHAT_API_KEY')}", 'X-Auth-Email' => 'christian@gxb.vc' }
  chat = new_session
  chat.get('/chat_api/tools', headers: chat_headers)
  raise "Chat API tools status #{chat.response.status}" unless chat.response.status == 200

  chat_tools = JSON.parse(chat.response.body).fetch('tools').map { |tool| tool.fetch('name') }.sort
  raise "Chat API tools #{chat_tools}" unless chat_tools == %w[create_template load_template search_documents
                                                                search_templates send_documents]

  chat.post('/chat_api/tools', params: { tool: 'search_templates', arguments: { q: BAILEY_NAME } }.to_json,
                               headers: chat_headers.merge('Content-Type' => 'application/json'))
  raise "Chat API search_templates status #{chat.response.status}" unless chat.response.status == 200

  found = JSON.parse(chat.response.body).fetch('templates')
  raise 'Chat API search_templates did not find Bailey v6' unless found.any? do |t|
    t['id'] == BAILEY_TEMPLATE_ID && t['name'] == BAILEY_NAME
  end

  puts "PASS: Chat API lists 5 tools and search_templates finds template #{BAILEY_TEMPLATE_ID}"

  puts 'PASS: only GXB migrations applied, Bailey v6 completed, signing links public, /setup locked, ' \
       'Chat API read-only tools'
else
  abort "Unknown phase #{phase}"
end
