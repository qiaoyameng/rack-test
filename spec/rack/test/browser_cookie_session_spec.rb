# frozen_string_literal: true

require_relative '../../spec_helper'

describe 'Rack::Test::Session browser cookies' do
  RESOLVER = ->(host) { host.split('.').last(3).join('.') }
  TARGET = 'target.accounts.example'
  SOURCE = 'source.accounts.example'

  def build_session
    received = []

    source_app = lambda do |env|
      request = Rack::Request.new(env)
      received << [request.request_method, request.host, request.cookies.dup]
      status = request.post? && request.POST['status'] == '307' ? 307 : 302
      [status, { 'location' => "https://#{TARGET}/landing" }, []]
    end

    target_app = lambda do |env|
      request = Rack::Request.new(env)

      if request.get? && request.path_info == '/set'
        cookies = [
          'strict=1; path=/; secure; samesite=strict',
          'lax=1; path=/; secure; samesite=lax',
          'none=1; path=/; secure; samesite=none'
        ]
        [200, { 'set-cookie' => cookies }, ['set']]
      else
        received << [request.request_method, request.host, request.cookies.dup]
        [200, {}, [request.cookies.inspect]]
      end
    end

    router = lambda do |env|
      case env['HTTP_HOST']
      when SOURCE
        source_app.call(env)
      when TARGET
        target_app.call(env)
      else
        [404, {}, []]
      end
    end

    session = Rack::Test::Session.new(
      router,
      default_same_site: 'lax',
      registrable_domain_resolver: RESOLVER
    )

    [session, received]
  end

  def context(host, navigation)
    {
      top_level_site: "https://#{host}",
      initiator_site: "https://#{host}",
      top_level_navigation: navigation
    }
  end

  it 'applies SameSite rules to the app receiving each redirect hop and subresource' do
    session, received = build_session

    session.get("https://#{TARGET}/set", {}, browser_context: context(TARGET, true))
    session.post("https://#{SOURCE}/submit", {}, browser_context: context(SOURCE, true))
    session.follow_redirect!
    session.get("https://#{TARGET}/resource", {}, browser_context: context(SOURCE, false))
    session.get("https://#{TARGET}/resource", {}, browser_context: context(TARGET, false))

    received.must_equal [
      ['POST', SOURCE, {}],
      ['GET', TARGET, { 'lax' => '1', 'none' => '1' }],
      ['GET', TARGET, { 'none' => '1' }],
      ['GET', TARGET, { 'strict' => '1', 'lax' => '1', 'none' => '1' }]
    ]
  end

  it 'uses the actual method for each 307 redirect hop' do
    session, received = build_session

    session.get("https://#{TARGET}/set", {}, browser_context: context(TARGET, true))
    session.post(
      "https://#{SOURCE}/submit",
      { 'status' => '307' },
      browser_context: context(SOURCE, true)
    )
    session.follow_redirect!

    session.last_request.request_method.must_equal 'POST'
    received.must_equal [
      ['POST', SOURCE, {}],
      ['POST', TARGET, { 'none' => '1' }]
    ]
  end

  it 'keeps ordinary sessions compatible when browser context is not enabled' do
    app = lambda do |env|
      request = Rack::Request.new(env)
      if request.get? && request.path_info == '/set'
        [
          200,
          { 'set-cookie' => 'strict=1; domain=accounts.example; path=/; secure; samesite=strict' },
          []
        ]
      else
        [200, {}, [request.cookies.inspect]]
      end
    end
    session = Rack::Test::Session.new(app)

    session.get('https://target.accounts.example/set')
    session.post('https://source.accounts.example/submit')

    session.last_request.cookies.must_equal 'strict' => '1'
  end

  it 'restores the browser context when restoring state' do
    session, _received = build_session

    session.restore_state do
      session.get("https://#{TARGET}/set", {}, browser_context: context(TARGET, true))
    end

    session.instance_variable_get(:@last_browser_context).must_be_nil
  end
end
