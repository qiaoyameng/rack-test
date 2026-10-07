# frozen_string_literal: true

require 'uri'

module Rack
  module Test
    # Default resolver for the registrable domain of a host. Uses the
    # last two labels of the host. It deliberately does not consult the
    # public suffix list. Inject a custom resolver (any object responding
    # to #registrable_domain) for hosts where the last two labels are not
    # the registrable domain, such as example.co.uk.
    class DomainResolver
      def registrable_domain(host)
        labels = host.to_s.downcase.split('.')
        labels.length > 2 ? labels.last(2).join('.') : labels.join('.')
      end
    end

    # A browser-like context for a request, used to enforce the SameSite
    # cookie sending rules (Strict/Lax/None) that Rack::Test does not
    # apply by default. Assign one to Rack::Test::Session#browser_context
    # to enable enforcement, or pass one to Rack::Test::CookieJar#for and
    # #merge directly.
    #
    # The context records the schemeful site (scheme and registrable
    # domain) of the top-level document, the site that initiated the
    # request, whether the request is a top-level navigation, and the
    # request method. Sites are compared including their scheme, so
    # http://example.org and https://example.org are different sites.
    #
    # The policy for cookies without a SameSite attribute must be given
    # explicitly via the required default_same_site keyword.
    class BrowserContext
      # Request methods considered safe for SameSite=Lax top-level
      # navigations.
      SAFE_METHODS = %w[GET HEAD OPTIONS TRACE].freeze

      # The schemeful site of the top-level document.
      attr_reader :top_level_site

      # The schemeful site that initiated the request. Defaults to the
      # top-level site.
      attr_reader :initiator_site

      # The request method used when evaluating SameSite rules.
      attr_reader :method

      # The policy applied to cookies without a SameSite attribute,
      # one of :strict, :lax, or :none.
      attr_reader :default_same_site

      # The resolver used to compute registrable domains.
      attr_reader :resolver

      def initialize(top_level_site:, default_same_site:, initiator_site: nil,
                     top_level_navigation: false, method: 'GET', resolver: DomainResolver.new)
        @default_same_site = default_same_site.to_sym
        unless %i[strict lax none].include?(@default_same_site)
          raise ArgumentError,
                "default_same_site must be :strict, :lax, or :none: #{default_same_site.inspect}"
        end

        @resolver = resolver
        @top_level_site = site_for(top_level_site)
        @initiator_site = initiator_site ? site_for(initiator_site) : @top_level_site
        @top_level_navigation = top_level_navigation
        self.method = method
      end

      # Whether the request is a top-level navigation.
      def top_level_navigation?
        @top_level_navigation
      end

      # A copy of the context using the given request method, so redirect
      # chains keep the original navigation context while each hop is
      # evaluated with its actual request method.
      def with_method(method)
        copy = dup
        copy.send(:method=, method)
        copy
      end

      # Whether the cookie may be sent to the given URI in this context,
      # according to SameSite rules only. The Secure, Domain, and Path
      # checks must also pass; those are handled by the cookie jar.
      def send_cookie?(cookie, uri)
        return true if initiator_site == site_for(uri)

        case cookie.same_site || default_same_site
        when :none
          true
        when :lax
          top_level_navigation? && SAFE_METHODS.include?(@method)
        else
          false
        end
      end

      # Whether the cookie may be stored when received in this context.
      # Browsers reject SameSite=None cookies without the Secure attribute.
      def acceptable_cookie?(cookie)
        cookie.same_site != :none || cookie.secure?
      end

      private

      attr_writer :method

      # The schemeful site for the given URI or string: the scheme and
      # the registrable domain. Ports, paths, and subdomains are ignored.
      def site_for(uri)
        uri = URI.parse(uri) if uri.is_a?(String)
        host = uri.host
        scheme = uri.scheme
        unless host
          host = uri.to_s
          scheme = nil
        end
        "#{scheme}://#{resolver.registrable_domain(host)}"
      end
    end
  end
end
