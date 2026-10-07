# frozen_string_literal: true

module Rack
  module Test
    # Rack::Test::OpenResponse is a streaming response returned by
    # Rack::Test::Session#open_response.  Unlike Rack::MockResponse, the
    # response body is not buffered up front.  The status and headers are
    # available as soon as the app returns, and the body is consumed chunk
    # by chunk under the control of the caller.  This makes it possible to
    # test long-lived streaming responses without an HTTP server, and
    # without requiring the body to be re-enumerable.
    #
    # The body is only iterated once, lazily, as chunks are requested.
    # Iteration can be paused and resumed at will, and the response can be
    # closed early via #close.  In all cases (full consumption, early
    # close, block exit, or an error while reading), the body is closed
    # exactly once.
    class OpenResponse
      # The HTTP status code of the response, as an Integer.
      attr_reader :status

      # The response headers.  Available as soon as the response is opened,
      # before any of the body is consumed.
      attr_reader :headers

      # The response errors, if any.
      attr_reader :errors

      # The chunks of the response body received so far.  Chunks received
      # before a read error or before the response is closed remain
      # available here.
      attr_reader :chunks

      def initialize(status, headers, body, errors) # :nodoc:
        @status = status.to_i
        @headers = headers
        @body = body
        @errors = errors
        @chunks = []
        @fiber = nil
        @finished = false
        @closed = false
      end

      # Return the value of the response header for the given field.
      def [](field)
        @headers[field]
      end

      # Read and return the next chunk of the response body.  Returns nil
      # if the body is fully consumed or the response has been closed.
      # Pauses the body between calls, so the body is only iterated once
      # even if reads are interleaved with other work.  If the body raises
      # while being read, the error is raised, the response is closed, and
      # the chunks received so far remain available in #chunks.
      def read
        return nil if @finished || @closed

        @fiber ||= Fiber.new do
          @body.each { |chunk| Fiber.yield(chunk) }
        end

        begin
          chunk = @fiber.resume
        rescue Exception
          @finished = true
          close
          raise
        end

        if @fiber.alive?
          @chunks << chunk
          chunk
        else
          @finished = true
          close
          nil
        end
      end

      # Yield each remaining chunk of the response body to the block.
      # Returns an enumerator if no block is given.  Breaking out of the
      # block pauses the body, and iteration can later be resumed with
      # #read or another call to #each.
      def each
        return enum_for(__method__) unless block_given?

        while (chunk = read)
          yield chunk
        end

        self
      end

      # Close the response body.  Called automatically when the body is
      # fully consumed, when a read raises, and (for the block form of
      # Rack::Test::Session#open_response) when the block exits.  Can also
      # be called directly to stop consuming the body early.  Only closes
      # the underlying body the first time it is called; later calls are
      # no-ops.
      def close
        return if @closed

        @closed = true
        @body.close if @body.respond_to?(:close)
        nil
      end

      # Whether the response has been closed.
      def closed?
        @closed
      end

      # Whether the response body has been fully consumed.
      def finished?
        @finished
      end
    end
  end
end
