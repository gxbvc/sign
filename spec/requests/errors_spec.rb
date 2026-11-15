# frozen_string_literal: true

describe 'Error pages for scanner paths' do
  def call_errors_app(path, accept)
    env = Rack::MockRequest.env_for(path, 'HTTP_ACCEPT' => accept, 'HTTP_HOST' => 'www.example.com',
                                          'HTTP_REFERER' => 'https://evil.example/')
    env['action_dispatch.exception'] = ActionController::RoutingError.new("No route matches #{path}")
    env['action_dispatch.original_path'] = path
    env['PATH_INFO'] = '/404'
    env['action_dispatch.request.path_parameters'] = { format: File.extname(path).delete('.') }
    ErrorsController.action(:show).call(env)
  end

  accepts = ['*/*', 'text/javascript', 'application/javascript']

  ['/secrets.js', '/env.js', '/config/keys.js', '/data.xml'].each do |path|
    accepts.each do |accept|
      it "returns 404 for #{path} with Accept #{accept}" do
        status, = call_errors_app(path, accept)

        expect(status).to eq(404)
      end
    end
  end
end
