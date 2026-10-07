# frozen_string_literal: true

module Rack
  module Test
    # Wraps a Rack response opened for streaming via
    # Rack::Test::Session#open_response. Unlike Rack::MockResponse, the
    # body is not buffered up front. The status and headers are available
    # immediately, and the body is consumed chunk by chunk under the
    # control of the caller. The body does not need to be re-enumerable;
    # it is enumerated at most once.
    class OpenResponse
      # The HTTP status code returned by the application.
      attr_reader :status

      # The response headers returned by the application. Available as
      # soon as the response is opened, before any of the body is read.
      attr_reader :headers

      def initialize(status, headers, body, &on_close) # :nodoc:
        @status = status
        @headers = headers
        @body = body
        @on_close = on_close
        @chunks = []
        @chunk_enumerator = nil
        @closed = false
      end

      # The body chunks received so far, joined into a single string.
      # Chunks received before a read failure are retained.
      def body
        @chunks.join
      end

      # Whether the response body has been closed, either by fully
      # consuming it, by an explicit #close, or by a read failure.
      def closed?
        @closed
      end

      # Read and return the next body chunk, or nil if the body has been
      # fully consumed or the response is closed. Fully consuming the
      # body closes the response. If the application raises while
      # producing a chunk, the response is closed and the error is
      # re-raised, but the status, headers, and chunks already received
      # remain available.
      def read_chunk
        return nil if closed?

        @chunk_enumerator ||= @body.enum_for(:each)
        begin
          chunk = @chunk_enumerator.next
        rescue StopIteration
          close
          nil
        rescue Exception
          close
          raise
        else
          @chunks << chunk
          chunk
        end
      end

      # Yield each remaining body chunk to the block, or return an
      # enumerator for the remaining chunks if no block is given.
      def each_chunk
        return enum_for(:each_chunk) unless block_given?

        while (chunk = read_chunk)
          yield chunk
        end
        self
      end

      # Close the response body. Idempotent: the body is closed and the
      # close callback runs at most once, no matter how the response
      # ends (fully consumed, explicitly closed, or read failure).
      def close
        return self if closed?

        @closed = true
        @body.close if @body.respond_to?(:close)
        @on_close.call(self) if @on_close
        self
      end
    end
  end
end
