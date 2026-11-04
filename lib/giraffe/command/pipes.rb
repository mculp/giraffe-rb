# frozen_string_literal: true

require_relative "../errors"

module Giraffe
  class Command
    # The threads at a child's three pipes: one feeds its stdin while two drain its stdout and stderr. They all run
    # at once because a child that fills a pipe nobody reads waits for us while we wait for it. They start as soon
    # as the pipes are made.
    class Pipes
      # A read waits for this many bytes or the end of the stream, so the output limit is checked a chunk at a time.
      CHUNK = 16_384

      def initialize(stdin, stdout, stderr, invocation)
        @stdin, @invocation = stdin, invocation
        @readers = [stdout, stderr].map { |stream| thread { read_all(stream) } }
        @writer = thread { feed }
      end

      def threads = [*@readers, @writer]

      # A reader that has stopped has either finished or failed, and only asking for its value says which. Asked
      # while the child still runs, it stops a command that is past its output limit at once.
      def check! = @readers.each { |reader| reader.value unless reader.alive? }

      # What the child wrote to stdout and to stderr, once every thread is done.
      def output
        @writer.value
        @readers.map(&:value)
      end

      # A thread behind a descendant that still holds a pipe open gets a second, and is then left for Open3 to end
      # by closing the pipe.
      def close
        @stdin.close unless @stdin.closed?
        @writer.join(1)
        @readers.each { |reader| reader.join(1) }
      end

      private

      # What goes wrong in it reaches whoever joins it, and is not printed besides.
      def thread
        Thread.new do
          Thread.current.report_on_exception = false
          yield
        end
      end

      def read_all(stream)
        data = +""
        each_chunk(stream) { |chunk| within_limit!(data << chunk) }
        data
      end

      def each_chunk(stream)
        while (chunk = stream.read(CHUNK))
          yield chunk
        end
      end

      def within_limit!(data)
        raise CommandLimit, "#{@invocation.label} output exceeds #{@invocation.limit} bytes" if data.bytesize > @invocation.limit
      end

      # A child that stops reading closes the pipe on us, which is its own choice and no failure of the run.
      def feed
        @stdin.write(@invocation.input) if @invocation.input
      rescue Errno::EPIPE
        nil
      ensure
        @stdin.close unless @stdin.closed?
      end
    end
  end
end
