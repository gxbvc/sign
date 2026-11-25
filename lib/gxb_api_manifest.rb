# frozen_string_literal: true

require 'json'
require 'digest'

# GXB API manifest (GET /openapi.json): the six Sign operations the gateway (api.gxb.vc) shows to AI apps.
# Contract: the GXB API service contract, section 3. The same document for every person; per-person rules are
# in GET /gxb/access and in each operation. Plain Ruby (no Rails), so the gateway's manifest check can
# read it on a laptop: ruby -Ilib -rgxb_api_manifest -e 'puts GxbApiManifest.json'
#
# Effects were chosen from the code in GxbApiOperations (lib/gxb_api_operations.rb):
# - template.list, template.get, document.list and signature_request.preview only read.
# - template.create saves a template (and DocuSeal queues its template.created webhooks to the account's own
#   webhook URLs, if any): state_change.
# - signature_request.create saves a submission and emails every signer a signing link at once. The emails
#   cannot be called back: state_change and external_send, with approval required.
module GxbApiManifest
  SERVICE = 'sign'
  PREFIX = '/gxb/v1'

  module_function

  def json
    JSON.generate(document)
  end

  def document
    body = body_without_version
    body.merge('info' => body['info'].merge('version' => revision(body)))
  end

  # The manifest revision: a hash of the whole document without info.version, so it changes whenever any
  # operation, schema or effect changes.
  def revision(body = body_without_version)
    "#{SERVICE}-#{Digest::SHA256.hexdigest(JSON.generate(body))[0, 16]}"
  end

  def body_without_version
    {
      'openapi' => '3.1.0',
      'info' => {
        'title' => 'GXB Sign',
        'description' => 'Document templates and signature requests in GXB Sign (sign.gxb.vc). Any active ' \
                         'GXB Auth person may use it. The first operation with a write token makes the ' \
                         "person's own Sign account (linked to the Auth person); reads before that see an " \
                         'empty account.'
      },
      'paths' => paths,
      'components' => { 'schemas' => schemas }
    }
  end

  def x_gxb(resource, action, effects, idempotent:, approval: 'none')
    { 'resource' => "#{SERVICE}.#{resource}", 'action' => action, 'effects' => effects,
      'idempotent' => idempotent, 'approval' => approval, 'lifecycle' => 'stable' }
  end

  def ref(name)
    { '$ref' => "#/components/schemas/#{name}" }
  end

  def json_response(description, schema)
    { 'description' => description, 'content' => { 'application/json' => { 'schema' => schema } } }
  end

  def error_responses
    # Plain Ruby (no ActiveSupport index_with), so this file also loads outside Rails.
    # rubocop:disable Rails/IndexWith
    %w[400 403 404 409 422 503].to_h { |code| [code, json_response('Error', ref('Error'))] }
    # rubocop:enable Rails/IndexWith
  end

  def query(name, schema, description, required: false)
    { 'name' => name, 'in' => 'query', 'required' => required, 'description' => description, 'schema' => schema }
  end

  def list_parameters(filter_ref, sort_values, field_values)
    [
      query('q', { 'type' => 'string', 'maxLength' => 200 }, 'Words to find (see the operation description).'),
      query('filter', ref(filter_ref), 'Conditions, all of which must match. See the operation description.'),
      query('sort', { 'type' => 'array', 'maxItems' => 1, 'items' => { 'type' => 'string', 'enum' => sort_values } },
            'One sort field; a leading - means descending. Ties are broken by id. Default -created_at.'),
      query('fields', { 'type' => 'array', 'maxItems' => field_values.size, 'uniqueItems' => true,
                        'items' => { 'type' => 'string', 'enum' => field_values } },
            'Only these fields in each record (id is always included).'),
      query('cursor', { 'type' => 'string', 'maxLength' => 200 }, 'meta.next_cursor from the page before.'),
      query('limit', { 'type' => 'integer', 'minimum' => 1, 'maximum' => 100, 'default' => 25 }, 'Page size.')
    ]
  end

  TEMPLATE_FIELDS = %w[name folder author_email roles version created_at updated_at].freeze
  DOCUMENT_FIELDS = %w[template_id template_name status submitters documents_url created_at completed_at].freeze

  def paths
    {
      "#{PREFIX}/templates" => { 'get' => template_list, 'post' => template_create },
      "#{PREFIX}/templates/{template_id}" => { 'get' => template_get },
      "#{PREFIX}/documents" => { 'get' => document_list },
      "#{PREFIX}/signature_requests/preview" => { 'get' => signature_request_preview },
      "#{PREFIX}/signature_requests" => { 'post' => signature_request_create }
    }
  end

  def template_list
    {
      'operationId' => 'sign.template.list',
      'summary' => 'List my document templates',
      'description' => "Active templates in the person's Sign account that the person may see, newest first. " \
                       'q matches the template name. Filter fields: folder (eq: the folder name), ' \
                       'author_email (eq: an email, or me for the person), created_at (gt, gte, lt, lte: an ' \
                       'ISO 8601 time). Sort fields: created_at, name.',
      'x-gxb' => x_gxb('template', 'list', [], idempotent: true),
      'parameters' => list_parameters('TemplateFilter', %w[created_at -created_at name -name], TEMPLATE_FIELDS),
      'responses' => { '200' => json_response('One page of templates', ref('TemplatePage')) }.merge(error_responses)
    }
  end

  def template_get
    {
      'operationId' => 'sign.template.get',
      'summary' => 'Load one template with its fields and signing roles',
      'description' => 'The template, its signing roles (use them as submitter roles in ' \
                       'sign.signature_request.preview) and its named fields with type and role. version is a ' \
                       'hash of the fields, roles and documents: it changes when the template changes.',
      'x-gxb' => x_gxb('template', 'get', [], idempotent: true),
      'parameters' => [{ 'name' => 'template_id', 'in' => 'path', 'required' => true,
                         'description' => 'The template id.', 'schema' => { 'type' => 'integer', 'minimum' => 1 } }],
      'responses' => { '200' => json_response('The template', data_of(ref('TemplateDetail'))) }.merge(error_responses)
    }
  end

  def template_create
    {
      'operationId' => 'sign.template.create',
      'summary' => 'Create a document template',
      'description' => 'Makes a template in the person\'s Sign account. With url (a public https link to a ' \
                       'PDF, at most 20 MB) the PDF is uploaded and its form fields are read; without url the ' \
                       'template is empty and edit_url opens it in the browser to upload a file. Signature ' \
                       'fields are placed in the browser editor. Sends no email. Send an Idempotency-Key: a ' \
                       'repeat with the same key gives the first template back.',
      'x-gxb' => x_gxb('template', 'create', ['state_change'], idempotent: false),
      'requestBody' => { 'required' => true,
                         'content' => { 'application/json' => { 'schema' => ref('NewTemplate') } } },
      'responses' => { '201' => json_response('The new template', data_of(ref('NewTemplateResult'))) }
        .merge(error_responses)
    }
  end

  def document_list
    {
      'operationId' => 'sign.document.list',
      'summary' => 'List my signature requests and signed documents',
      'description' => "Active submissions in the person's Sign account that the person may see, newest " \
                       'first. q matches a signer email, name or phone, or the template name. Filter fields: ' \
                       'status (eq: pending, sent, opened, partially_completed, completed, declined, expired), ' \
                       'template_id (eq), author_email (eq: the sender\'s email, or me), created_at and ' \
                       'completed_at (gt, gte, lt, lte: an ISO 8601 time). Sort fields: created_at.',
      'x-gxb' => x_gxb('document', 'list', [], idempotent: true),
      'parameters' => list_parameters('DocumentFilter', %w[created_at -created_at], DOCUMENT_FIELDS),
      'responses' => { '200' => json_response('One page of documents', ref('DocumentPage')) }.merge(error_responses)
    }
  end

  def signature_request_preview
    {
      'operationId' => 'sign.signature_request.preview',
      'summary' => 'Preview a signature request before it is sent',
      'description' => 'Checks a send without sending: the template must be active and have fields, every ' \
                       'role must be a role of the template, and every submitter needs an email. Answers the ' \
                       'exact recipients who would get an email, the template version, and a confirmation ' \
                       'value. Show the recipients to the person; sign.signature_request.create needs the same ' \
                       'template, submitters and this confirmation. Sends nothing and saves nothing.',
      'x-gxb' => x_gxb('signature_request', 'preview', [], idempotent: true),
      'parameters' => [
        query('template_id', { 'type' => 'integer', 'minimum' => 1 }, 'The template to send.', required: true),
        query('submitters', ref('Submitters'), 'The signers, one per template role.', required: true)
      ],
      'responses' => { '200' => json_response('What would be sent', data_of(ref('SignaturePreview'))) }
        .merge(error_responses)
    }
  end

  def signature_request_create
    {
      'operationId' => 'sign.signature_request.create',
      'summary' => 'Send a template for signature (emails real people, cannot be undone)',
      'description' => 'Sends the template to the submitters: each one gets a signing link by email at once. ' \
                       'Call sign.signature_request.preview first and pass its confirmation; a changed ' \
                       'template or a different list of submitters is refused (409). Send an Idempotency-Key: ' \
                       'a repeat with the same key sends nothing and gives the first result back.',
      'x-gxb' => x_gxb('signature_request', 'create', %w[state_change external_send],
                       idempotent: false, approval: 'required'),
      'requestBody' => { 'required' => true,
                         'content' => { 'application/json' => { 'schema' => ref('NewSignatureRequest') } } },
      'responses' => { '201' => json_response('The sent request', data_of(ref('SignatureRequest'))) }
        .merge(error_responses)
    }
  end

  def data_of(schema)
    { 'type' => 'object', 'properties' => { 'data' => schema } }
  end

  def condition(fields, ops)
    {
      'type' => 'object',
      'properties' => {
        'field' => { 'type' => 'string', 'enum' => fields },
        'op' => { 'type' => 'string', 'enum' => ops },
        'value' => { 'type' => %w[string integer] }
      },
      'required' => %w[field op value],
      'additionalProperties' => false
    }
  end

  def filter(condition_ref)
    { 'type' => 'object',
      'properties' => { 'and' => { 'type' => 'array', 'maxItems' => 10, 'items' => ref(condition_ref) } },
      'required' => ['and'], 'additionalProperties' => false }
  end

  def page(item_ref)
    { 'type' => 'object',
      'properties' => {
        'data' => { 'type' => 'array', 'items' => ref(item_ref) },
        'meta' => { 'type' => 'object', 'properties' => { 'next_cursor' => { 'type' => %w[string null] },
                                                          'has_more' => { 'type' => 'boolean' } } }
      } }
  end

  def string(max = 200)
    { 'type' => 'string', 'maxLength' => max }
  end

  def time
    { 'type' => %w[string null], 'format' => 'date-time' }
  end

  def submitter_schema
    {
      'type' => 'object',
      'properties' => {
        'email' => { 'type' => 'string', 'format' => 'email', 'minLength' => 3, 'maxLength' => 254 },
        'name' => string,
        'role' => { 'type' => 'string', 'maxLength' => 200,
                    'description' => 'A role name from sign.template.get. Without it, the signer gets the ' \
                                     'role at the same position.' },
        'phone' => string(40),
        'fields' => {
          'type' => 'array', 'maxItems' => 100,
          'description' => 'Values to fill in for this signer, read-only for them.',
          'items' => { 'type' => 'object',
                       'properties' => { 'name' => string, 'value' => { 'type' => %w[string number boolean] } },
                       'required' => %w[name value], 'additionalProperties' => false }
        }
      },
      'required' => ['email'],
      'additionalProperties' => false
    }
  end

  # rubocop:disable Metrics/MethodLength
  def schemas
    {
      'Error' => { 'type' => 'object',
                   'properties' => { 'error' => { 'type' => 'object',
                                                  'properties' => { 'code' => { 'type' => 'string' },
                                                                    'message' => { 'type' => 'string' } } } } },
      'TemplateFilter' => filter('TemplateCondition'),
      'TemplateCondition' => condition(%w[folder author_email created_at], %w[eq gt gte lt lte]),
      'DocumentFilter' => filter('DocumentCondition'),
      'DocumentCondition' => condition(%w[status template_id author_email created_at completed_at],
                                       %w[eq gt gte lt lte]),
      'Template' => {
        'type' => 'object',
        'properties' => {
          'id' => { 'type' => 'integer' }, 'name' => { 'type' => 'string' },
          'folder' => { 'type' => 'string' }, 'author_email' => { 'type' => 'string' },
          'roles' => { 'type' => 'array', 'items' => { 'type' => 'string' } },
          'version' => { 'type' => 'string' }, 'created_at' => time, 'updated_at' => time
        }
      },
      'TemplatePage' => page('Template'),
      'TemplateDetail' => {
        'type' => 'object',
        'properties' => {
          'id' => { 'type' => 'integer' }, 'name' => { 'type' => 'string' },
          'roles' => { 'type' => 'array', 'items' => { 'type' => 'string' } },
          'fields' => { 'type' => 'array',
                        'items' => { 'type' => 'object',
                                     'properties' => { 'name' => { 'type' => 'string' },
                                                       'type' => { 'type' => 'string' },
                                                       'role' => { 'type' => %w[string null] },
                                                       'required' => { 'type' => 'boolean' } } } },
          'version' => { 'type' => 'string' }, 'edit_url' => { 'type' => 'string' }
        }
      },
      'NewTemplate' => {
        'type' => 'object',
        'properties' => {
          'name' => { 'type' => 'string', 'minLength' => 1, 'maxLength' => 200 },
          'url' => { 'type' => 'string', 'maxLength' => 2000,
                     'description' => 'Optional public https URL of a PDF file.' }
        },
        'required' => ['name'],
        'additionalProperties' => false
      },
      'NewTemplateResult' => {
        'type' => 'object',
        'properties' => { 'id' => { 'type' => 'integer' }, 'name' => { 'type' => 'string' },
                          'version' => { 'type' => 'string' }, 'edit_url' => { 'type' => 'string' } }
      },
      'Submitters' => { 'type' => 'array', 'minItems' => 1, 'maxItems' => 20, 'items' => ref('Submitter') },
      'Submitter' => submitter_schema,
      'Document' => {
        'type' => 'object',
        'properties' => {
          'id' => { 'type' => 'integer' }, 'template_id' => { 'type' => %w[integer null] },
          'template_name' => { 'type' => %w[string null] }, 'status' => { 'type' => 'string' },
          'submitters' => { 'type' => 'array', 'items' => ref('DocumentSubmitter') },
          'documents_url' => { 'type' => 'string' }, 'created_at' => time, 'completed_at' => time
        }
      },
      'DocumentSubmitter' => {
        'type' => 'object',
        'properties' => { 'email' => { 'type' => %w[string null] }, 'name' => { 'type' => %w[string null] },
                          'phone' => { 'type' => %w[string null] }, 'role' => { 'type' => %w[string null] },
                          'status' => { 'type' => 'string' } }
      },
      'DocumentPage' => page('Document'),
      'SignaturePreview' => {
        'type' => 'object',
        'properties' => {
          'template_id' => { 'type' => 'integer' }, 'template_name' => { 'type' => 'string' },
          'template_version' => { 'type' => 'string' },
          'submitters' => { 'type' => 'array', 'items' => ref('DocumentSubmitter') },
          'emails_to' => { 'type' => 'array', 'items' => { 'type' => 'string' } },
          'confirmation' => { 'type' => 'string' }
        }
      },
      'NewSignatureRequest' => {
        'type' => 'object',
        'properties' => {
          'template_id' => { 'type' => 'integer', 'minimum' => 1 },
          'submitters' => ref('Submitters'),
          'confirmation' => { 'type' => 'string', 'maxLength' => 200,
                              'description' => 'The confirmation from sign.signature_request.preview.' }
        },
        'required' => %w[template_id submitters confirmation],
        'additionalProperties' => false
      },
      'SignatureRequest' => {
        'type' => 'object',
        'properties' => { 'id' => { 'type' => 'integer' }, 'status' => { 'type' => 'string' },
                          'template_id' => { 'type' => 'integer' },
                          'submitters' => { 'type' => 'array', 'items' => ref('DocumentSubmitter') } }
      }
    }
  end
  # rubocop:enable Metrics/MethodLength
end
