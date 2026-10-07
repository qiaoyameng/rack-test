# frozen_string_literal: true

require 'uri'

module Rack
  module Test
    # Calculates the registrable domain for a host. This intentionally uses a
    # simple implementation without a public suffix list.
    module RegistrableDomainResolver
      module_function

      def call(host)
        host = host.downcase
        labels = host.split('.')

        return host if host.start_with?('[')
        return host if labels.length == 4 && labels.all? { |label| label =~ /\A(?:\d{1,2}|1\d\d|2[0-4]\d|25[0-5])\z/ }
        return host if labels.length <= 2

        labels.last(2).join('.')
      end
    end

    # A site consists of a scheme and a registrable domain.
    class Site
      attr_reader :scheme, :registrable_domain

      def self.from(value, resolver = RegistrableDomainResolver)
        return value.dup if value.is_a?(self)

        uri = value.is_a?(URI::Generic) ? value : URI.parse(value.to_s)
        host = uri.host
        raise ArgumentError, "site must include a host: #{value.inspect}" unless host

        scheme = (uri.scheme || 'http').downcase
        domain = resolver.call(host.downcase).downcase.sub(/\A\./, '')
        new(scheme, domain)
      end

      def initialize(scheme, registrable_domain)
        @scheme = scheme.downcase
        @registrable_domain = registrable_domain.downcase
      end

      def ==(other)
        other.is_a?(self.class) &&
          scheme == other.scheme &&
          registrable_domain == other.registrable_domain
      end
      alias eql? ==

      def hash
        [self.class, scheme, registrable_domain].hash
      end

      def to_s
        "#{scheme}://#{registrable_domain}"
      end

      def initialize_copy(other)
        super
        @scheme = scheme.dup
        @registrable_domain = registrable_domain.dup
      end
    end

    # Describes the browser context in which a request is made.
    class BrowserContext
      SAFE_METHODS = %w[GET HEAD OPTIONS TRACE].freeze

      attr_reader :top_level_site, :initiator_site, :request_method,
                  :default_same_site, :registrable_domain_resolver

      def self.wrap(context, request_method = nil, default_same_site = nil,
                    registrable_domain_resolver = RegistrableDomainResolver)
        if context.is_a?(self)
          resolver = if context.registrable_domain_resolver.equal?(RegistrableDomainResolver)
            registrable_domain_resolver
          else
            context.registrable_domain_resolver
          end
          policy = context.default_same_site || default_same_site

          return context.with_request(
            request_method,
            policy,
            resolver
          )
        end
        attributes = context.is_a?(Hash) ? context.transform_keys(&:to_s) : nil
        value = if attributes
          ->(*names) { attributes.values_at(*names.map(&:to_s)).compact.first }
        else
          ->(name) { context.public_send(name) if context.respond_to?(name) }
        end

        new(
          top_level_site: value.call(:top_level_site, :top_site, :site_for_cookies),
          initiator_site: value.call(:initiator_site, :initiator),
          top_level_navigation: attributes ?
            value.call(:top_level_navigation, :top_level, :top_level) :
            context.respond_to?(:top_level_navigation?) && context.top_level_navigation?,
          request_method: request_method || value.call(:request_method, :method),
          default_same_site:
            value.call(:default_same_site, :default_same_site_policy,
                       :unspecified_same_site, :same_site_default,
                       :default_samesite) || default_same_site,
          registrable_domain_resolver:
            value.call(:registrable_domain_resolver, :resolver) ||
            registrable_domain_resolver
        )
      end

      def initialize(top_level_site:, initiator_site:, top_level_navigation: false,
                     request_method: nil, default_same_site: nil,
                     registrable_domain_resolver: RegistrableDomainResolver)
        @registrable_domain_resolver = registrable_domain_resolver
        @top_level_site_source = top_level_site
        @initiator_site_source = initiator_site
        @top_level_site = Site.from(top_level_site, resolver) if top_level_site
        @initiator_site = Site.from(initiator_site, resolver) if initiator_site
        @top_level_navigation = top_level_navigation ? true : false
        @request_method = request_method && request_method.to_s.upcase
        @default_same_site = default_same_site && default_same_site.to_s.downcase
      end

      def top_level_navigation?
        @top_level_navigation
      end

      def for_request(request_method)
        with_request(request_method, default_same_site, resolver)
      end

      def with_request(request_method, default_same_site, resolver)
        self.class.new(
          top_level_site: @top_level_site_source,
          initiator_site: @initiator_site_source,
          top_level_navigation: top_level_navigation?,
          request_method: request_method || self.request_method,
          default_same_site: default_same_site || self.default_same_site,
          registrable_domain_resolver: resolver || self.registrable_domain_resolver
        )
      end

      def site_for(uri)
        Site.from(uri, resolver)
      end

      def same_site_request?(site)
        top_level_site == site && initiator_site == site
      end

      def lax_navigation?
        top_level_navigation? && SAFE_METHODS.include?(request_method)
      end

      private

      def initialize_copy(_other)
        super
        @top_level_site_source = @top_level_site_source.dup if @top_level_site_source
        @initiator_site_source = @initiator_site_source.dup if @initiator_site_source
        @registrable_domain_resolver = @registrable_domain_resolver
        @top_level_navigation = @top_level_navigation
        @request_method = @request_method && @request_method.dup
        @default_same_site = @default_same_site && @default_same_site.dup
        @top_level_site = top_level_site.dup if top_level_site
        @initiator_site = initiator_site.dup if initiator_site
      end

      def resolver
        @registrable_domain_resolver
      end
    end
  end
end
