# frozen_string_literal: true

# Run only in a disposable candidate on a temp copy of production data (deploy/candidate.rb mode B).
# Prints ids, names, statuses, and counts only. Never secrets or document contents.
abort 'Not a disposable data-copy check' unless ENV['SIGN_DATA_COPY_CHECK'] == 'true'
abort 'Migrations must be disabled for this check' unless ENV['RUN_MIGRATIONS'] == 'false'

BAILEY_TEMPLATE_ID = 2
BAILEY_NAME = 'GXB-Bailey Advisory Agreement v6 (2026-09-23)'
EXPECTED_SCHEMA = '20260819091500'

def schema_version
  ActiveRecord::Base.connection.select_value('SELECT MAX(version) FROM schema_migrations').to_s
end

def pending_migrations
  ActiveRecord::Base.connection_pool.migration_context.open.pending_migrations.map(&:version)
end

phase = ARGV.fetch(0)
case phase
when 'before'
  workdir = ENV.fetch('WORKDIR')
  raise 'dump.rdb present; queued jobs could run' if File.exist?(File.join(workdir, 'dump.rdb'))

  puts "INFO: schema_version=#{schema_version}"
  puts "INFO: pending_migrations=#{pending_migrations.size}"
  puts "INFO: users=#{User.count} templates=#{Template.count} submissions=#{Submission.count} submitters=#{Submitter.count}"
  puts 'PASS: pre-boot read (no dump.rdb)'
when 'after'
  before = ARGV.fetch(1)
  after = schema_version
  pending = pending_migrations
  puts "INFO: schema_version before=#{before} after=#{after} pending=#{pending.size}"
  raise 'Schema changed by boot' unless before == after && after == EXPECTED_SCHEMA
  raise "Pending migrations: #{pending.join(',')}" unless pending.empty?

  template = Template.find(BAILEY_TEMPLATE_ID)
  puts "INFO: template id=#{template.id} name=#{template.name.inspect} archived=#{template.archived_at.present?}"
  raise 'Bailey template name changed' unless template.name == BAILEY_NAME

  submitters = Submitter.joins(:submission).where(submissions: { template_id: template.id }).order(:id)
  submitters.each do |submitter|
    puts "INFO: submitter id=#{submitter.id} submission_id=#{submitter.submission_id} status=#{submitter.status}"
  end
  raise "Expected 2 Bailey submitters, got #{submitters.size}" unless submitters.size == 2
  raise 'Bailey submitters not all completed' unless submitters.all? { |s| s.completed_at.present? }

  session = ActionDispatch::Integration::Session.new(Rails.application)
  session.host!('localhost')
  session.get('/setup')
  raise "Setup open on production copy: #{session.response.status}" unless session.response.redirect?

  session.get('/')
  html = Nokogiri::HTML(session.response.body)
  if session.response.status == 200
    raise 'Wrong page title' unless html.at_css('title').text.strip == 'GXB Sign'
    raise 'Missing attribution' unless html.css('a').any? { |a| a.text == 'DocuSeal' }
    raise 'Missing source' unless html.at_css('a[href="/gxb-sign/source.tar.gz"]')
  end
  puts "INFO: landing status=#{session.response.status}"
  puts 'PASS: schema unchanged, no pending migrations, Bailey v6 completed, /setup locked'
else
  abort "Unknown phase #{phase}"
end
