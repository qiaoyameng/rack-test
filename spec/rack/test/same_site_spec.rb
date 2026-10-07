# frozen-string-literal: true

require_relative '../../spec_helper'

describe 'SameSite browser context' do
  # Records the requests it receives, so specs can assert on the cookies
  # that actually arrived at each hop.
  class SameSiteRecorderApp
    attr_reader :requests

    def initialize(&handler)
      @handler = handler
      @requests = []
    end

    def call(env)
      @requests << env
      @handler.call(env)
    end

    def cookies_received(index = -1)
      @requests[index]['HTTP_COOKIE'].to_s.split('; ').reject(&:empty?).
        map { |pair| pair.split('=', 2) }.to_h
    end
  end

  TARGET_COOKIES = [
    'strict=1; SameSite=Strict; Secure',
    'lax=1; SameSite=Lax; Secure',
    'none=1; SameSite=None; Secure',
    'plain=1; Secure',
    'insecure_none=1; SameSite=None'
  ].join("\n").freeze

  ASSET_COOKIES = [
    'strict=1; SameSite=Strict; Secure',
    'none=1; SameSite=None; Secure'
  ].join("\n").freeze

  let(:target_app) do
    SameSiteRecorderApp.new do |env|
      case env['PATH_INFO']
      when '/seed'
        [200, {'content-type' => 'text/plain', 'set-cookie' => TARGET_COOKIES}, ['seeded']]
      when '/submit'
        [302, {'content-type' => 'text/plain', 'location' => 'https://target.test/done'}, []]
      else
        [200, {'content-type' => 'text/plain'}, ['ok']]
      end
    end
  end

  let(:asset_app) do
    SameSiteRecorderApp.new do |env|
      case env['PATH_INFO']
      when '/seed'
        [200, {'content-type' => 'text/plain', 'set-cookie' => ASSET_COOKIES}, ['seeded']]
      else
        [200, {'content-type' => 'text/plain'}, ['pixel']]
      end
    end
  end

  let(:router) do
    target = target_app
    assets = asset_app
    lambda do |env|
      case env['HTTP_HOST']
      when 'target.test' then target.call(env)
      when 'assets.test' then assets.call(env)
      else [404, {'content-type' => 'text/plain'}, ['not found']]
      end
    end
  end

  let(:session) { Rack::Test::Session.new(router) }

  def browser_context(**options)
    Rack::Test::BrowserContext.new(**{default_same_site: :lax}.merge(options))
  end

  def seed_cookies(session)
    session.browser_context = browser_context(top_level_site: 'https://target.test')
    session.get 'https://target.test/seed'
    session.browser_context = browser_context(top_level_site: 'https://assets.test')
    session.get 'https://assets.test/seed'
  end

  it 'sends cookies per SameSite rules on cross-site POST, redirect, and subresource requests' do
    seed_cookies(session)

    # SameSite=None without Secure is rejected when received.
    jar_names = session.cookie_jar.to_hash.keys
    jar_names.must_include 'strict'
    jar_names.must_include 'lax'
    jar_names.must_include 'none'
    jar_names.must_include 'plain'
    jar_names.wont_include 'insecure_none'

    # Cross-site form POST as a top-level navigation: only SameSite=None
    # cookies are sent, since POST is not a safe method.
    session.browser_context = browser_context(
      top_level_site: 'https://shop.test',
      initiator_site: 'https://shop.test',
      top_level_navigation: true,
      method: 'POST'
    )
    session.post 'https://target.test/submit'
    target_app.cookies_received.must_equal 'none' => '1'

    # The redirect keeps the original navigation context, but the GET hop
    # is evaluated with its actual method, so Lax cookies now go out.
    session.follow_redirect!
    target_app.cookies_received.must_equal 'lax' => '1', 'none' => '1', 'plain' => '1'

    # A cross-site subresource request is not a top-level navigation, so
    # only SameSite=None cookies are sent.
    session.browser_context = browser_context(
      top_level_site: 'https://shop.test',
      initiator_site: 'https://shop.test',
      top_level_navigation: false,
      method: 'GET'
    )
    session.get 'https://assets.test/pixel'
    asset_app.cookies_received.must_equal 'none' => '1'

    # Same-site requests send all stored cookies.
    session.browser_context = browser_context(top_level_site: 'https://target.test')
    session.get 'https://target.test/echo'
    target_app.cookies_received.must_equal(
      'strict' => '1', 'lax' => '1', 'none' => '1', 'plain' => '1'
    )
  end

  it 'keeps legacy behavior when no browser context is set' do
    session.get 'https://target.test/seed'

    # Without a browser context, SameSite=None without Secure is stored,
    # and every cookie matching the URI is sent, even cross-site.
    session.cookie_jar.to_hash.keys.must_include 'insecure_none'
    session.post 'https://target.test/submit'
    target_app.cookies_received.must_equal(
      'strict' => '1', 'lax' => '1', 'none' => '1', 'plain' => '1', 'insecure_none' => '1'
    )
  end
end
