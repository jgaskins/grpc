require "socket"
require "mutex"

require "./hpack"

module HTTP2
  class Error < Exception
  end

  abstract struct Frame
    TYPES = {
      Data,
      Headers,
      Priority,
      ResetStream,
      Settings,
      PushPromise,
      Ping,
      GoAway,
      WindowUpdate,
      Continuation,
    }

    getter payload, stream_id, flags

    class Error < HTTP2::Error
    end
    class InvalidTypeError < Error
    end

    macro inherited
      def type_byte : UInt8
        TYPE
      end
    end

    @[Flags]
    enum Flags : UInt8
      EndStream = 0x01
      EndHeaders = 0x04
      Padded = 0x08
      Priority = 0x20
    end

    def self.type(type : UInt8)
      TYPES.fetch(type) do
        raise InvalidTypeError.new("No frame type with value 0x#{type.to_s(16)}")
      end
    end

    def self.from_io(io : IO) : Frame
      length = (io.read_bytes(UInt8).to_u32 << 16) | io.read_bytes(UInt16, IO::ByteFormat::NetworkEndian)
      type = io.read_bytes(UInt8)
      flags = Flags.new(io.read_bytes(UInt8))

      # Stream id is a 31-bit number (lol)
      stream_id = io.read_bytes(UInt32, IO::ByteFormat::NetworkEndian) & 0b0111_1111_1111_1111_1111_1111_1111_1111

      payload = Bytes.new(length)
      io.read payload

      type(type).new(flags, stream_id, payload)
    end

    def initialize(@flags : Flags, @stream_id : UInt32, @payload : Bytes = Bytes.empty)
      if payload.size >= (1 << 24)
        raise ArgumentError.new("Cannot have a #{self.class} with a size of #{payload.size} (max #{1 << 24})")
      end
    end

    def to_s(io)
      # Length is a 24-byte value
      io.write_byte (@payload.bytesize >> 16).to_u8
      io.write_bytes @payload.bytesize.to_u16, IO::ByteFormat::NetworkEndian

      io.write_byte type_byte

      io.write_byte @flags.to_u8

      io.write_bytes (@stream_id & 0b0111_1111_1111_1111_1111_1111_1111_1111), IO::ByteFormat::NetworkEndian

      io.write @payload
    end

    abstract def type_byte : UInt8

    struct Data < Frame
      TYPE = 0x0_u8
    end

    struct Headers < Frame
      TYPE = 0x1_u8

      @headers = HTTP::Headers.new

      def decode_with(decoder : HPACK::Decoder) : HTTP::Headers
        @headers.merge! decoder.decode(payload)
      end

      def to_h
        @headers
      end
    end

    struct Priority < Frame
      TYPE = 0x2_u8
    end

    struct ResetStream < Frame
      TYPE = 0x3_u8
    end

    struct Settings < Frame
      TYPE = 0x4_u8

      enum Parameter : UInt16
        HeaderTableSize = 1
        EnablePush = 2
        MaxConcurrentStreams = 3
        InitialWindowSize = 4
        MaxFrameSize = 5
        MaxHeaderListSize = 6
      end

      def self.ack(settings : self)
        new(
          stream_id: settings.stream_id,
          flags: Flags::EndStream,
        )
      end

      def ack?
        flags.end_stream? # Settings ACK is the same bit as END_STREAM for other frame types
      end

      def params
        io = IO::Memory.new(@payload)
        params = Hash(Parameter, UInt32).new(initial_capacity: @payload.size / 6)

        until io.pos == @payload.size
          param = Parameter.from_value?(io.read_bytes(UInt16, IO::ByteFormat::NetworkEndian))
          value = io.read_bytes(UInt32, IO::ByteFormat::NetworkEndian)

          params[param] = value if param
        end

        params
      end
    end

    struct PushPromise < Frame
      TYPE = 0x5_u8
    end

    struct Ping < Frame
      TYPE = 0x6_u8

      def self.ack(ping : self) : self
        new(
          stream_id: ping.stream_id,
          payload: Bytes[0, 0, 0, 0, 0, 0, 0, 0],
          flags: Flags::EndStream,
        )
      end

      def ack?
        flags.end_stream? # Ping ACK is the same bit as END_STREAM for other frame types
      end
    end

    struct GoAway < Frame
      TYPE = 0x7_u8
    end

    struct WindowUpdate < Frame
      TYPE = 0x8_u8

      def size
        IO::Memory.new(@payload).read_bytes(UInt32, IO::ByteFormat::NetworkEndian) & 0b0111_1111_1111_1111_1111_1111_1111_1111
      end
    end

    struct Continuation < Frame
      TYPE = 0x9_u8
    end
  end

  module Handler
    property next_handler : Handler?

    abstract def call(context : Server::Context)

    def call_next(context : Server::Context)
      if handler = next_handler
        handler.call context
      end
    end
  end

  class Server
    @handler : HTTP2::Handler

    def initialize(handlers : Array)
      @handler = handlers.reduce do |prev_handler, next_handler|
        prev_handler.next_handler = next_handler
        next_handler
      end
    end

    class Context
      getter request : Request
      getter response : Response

      def initialize(@request, @response)
      end
    end

    class Response < IO
      getter headers = HTTP::Headers { ":status" => "200" }
      getter body = IO::Memory.new

      def read(bytes : Bytes)
        @body.read bytes
      end

      def write(bytes : Bytes) : Nil
        @body.write bytes
      end
    end
  end

  class ClearTextServer < Server
    def listen(host : String, port : Int32)
      server_socket = TCPServer.new(host, port)
      loop do
        socket = server_socket.accept
        Connection.new(socket).start do |connection, stream|
          handle connection, stream
        end
      end
    end

    def handle(connection, stream)
      if stream.state.half_closed_remote?
        spawn do
          request = Request.new(stream.headers, stream.data)
          response = Server::Response.new
          context = Server::Context.new(request, response)
          @handler.call context

          stream.send Frame::Headers.new(
            stream_id: stream.id,
            flags: Frame::Flags::EndHeaders,
            payload: connection.hpack_encode(response.headers),
          )
          stream.send Frame::Data.new(
            stream_id: stream.id,
            flags: Frame::Flags::None,
            payload: response.body.to_slice,
          )
          stream.send Frame::Headers.new(
            stream_id: stream.id,
            flags: Frame::Flags::EndStream | Frame::Flags::EndHeaders,
            payload: connection.hpack_encode(HTTP::Headers { "grpc-status" => "0" }),
          )
        end
      end
    end
  end

  class Request
    getter headers : HTTP::Headers
    getter body : IO?
    # getter trailers : HTTP::Headers?

    def initialize(@headers, @body)
    end

    def method : String
      headers[":method"]
    end

    def path : String
      headers[":path"]
    end
  end

  class Connection < IO
    PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".to_slice

    DEFAULTS = {
      initial_window_size: 65535,
      # max_frame_size: 16384,
      # max_header_list_size: 2 ** 31 - 1,
      # header_table_size: 4096,
    }

    @state : State = State::New
    @recv_buffer = Channel(Frame).new(32)
    @send_buffer = Channel(Frame).new(32)
    @socket : IO
    @streams = Hash(UInt32, Stream).new
    @hpack_encoder = HPACK::Encoder.new(huffman: true)
    @hpack_decoder = HPACK::Decoder.new
    @read_mutex = Mutex.new
    @write_mutex = Mutex.new

    def initialize(@socket, @initial_window_size : Int32 = DEFAULTS[:initial_window_size])
    end

    def start(&block : Connection, Stream ->)
      spawn do
        bytes = Bytes.new(PREFACE.bytesize)
        @socket.read(bytes)

        if bytes == PREFACE
          # Frame::Settings.new(flags: Frame::Settings::Flags::None, stream_id: 0, payload: Bytes.new(0)).to_s @socket

          loop do
            frame = read_frame
            stream = @streams.fetch(frame.stream_id) do |id|
              @streams[id] = Stream.new(self, id)
            end
            stream.receive frame, hpack_decoder: @hpack_decoder

            block.call self, stream

            if stream.state.closed?
              @streams.delete stream.id
            end
          end
        else
          @socket.close
          @state = State::Closed
          next
        end

      rescue ex : IO::EOFError
        # The client has closed the connection, so we don't actually need to do
        # anything here and we can exit normally.
      end
    end

    def hpack_encode(headers : HTTP::Headers)
      @hpack_encoder.encode(headers)
    end

    def stream
      @streams[0]
    end

    private def read_frame : Frame
      read_sync do
        Frame.from_io(@socket)
      end
    end

    def write_frame(frame : Frame)
      write_sync do
        frame.to_s @socket
      end
    end

    def closed?
      @state.closed?
    end

    def read(slice : Bytes)
      @socket.read slice
    end

    def write(slice : Bytes) : Nil
      @socket.write slice
    end

    private def read_sync(&block)
      @read_mutex.synchronize { return yield }
    end

    private def write_sync(&block)
      @write_mutex.synchronize { return yield }
    end

    enum State
      New
      Closed
    end
  end

  class Stream
    getter state = State::Idle
    getter initial_window_size : Int32 = 1 << 10
    getter window_size = 32_u32
    getter? push_enabled = false
    getter headers = HTTP::Headers.new
    getter! data : IO::Memory?
    getter id

    class InvalidOperation < Error
    end
    class StateError < Error
    end

    def initialize(@connection : Connection, @id : UInt32)
    end

    def send(data : Frame::Data)
      if state.idle?
        raise StateError.new("Cannot send #{data.class} frame in state #{state}")
      end

      if data.flags.end_stream?
        @state = State::Closed
      end

      @connection.write_frame data
    end

    def send(ping : Frame::Ping)
      @connection.write_frame ping
    end

    def send(settings : Frame::Settings)
      @connection.write_frame settings
    end

    def send(headers : Frame::Headers)
      @connection.write_frame headers

      case headers.flags
      when .end_stream?
        @state = State::Closed
      end
    end

    # Do we need this?
    # def send(push_promise : Frame::PushPromise)
    # end

    def receive(data : Frame::Data, **_kwargs)
      (io = @data ||= IO::Memory.new).write data.payload

      case state
      when .idle?, .open?
      else
        raise StateError.new("Cannot receive #{data.class} frame when in state #{state.inspect}")
      end

      case data.flags
      when .end_stream?
        @state = State::HalfClosedRemote
        io.rewind
      end
    end

    def receive(headers : Frame::Headers, hpack_decoder : HPACK::Decoder)
      @headers.merge! headers.decode_with(hpack_decoder)

      case state
      when .idle?
        @state = State::Open
      end

      case headers.flags
      when .end_stream?
        @state = State::HalfClosedRemote
      end
    end

    def receive(priority : Frame::Priority, **_kwargs)
    end

    def receive(reset_stream : Frame::ResetStream, **_kwargs)
    end

    def receive(push_promise : Frame::PushPromise, **_kwargs)
    end

    def receive(ping : Frame::Ping, **_kwargs)
      send Frame::Ping.ack(ping) unless ping.ack?
    end

    def receive(go_away : Frame::GoAway, **_kwargs)
    end

    def receive(window_update : Frame::WindowUpdate, **_kwargs)
      @window_size = window_update.size
    end

    def receive(continuation : Frame::Continuation, **_kwargs)
    end

    def receive(settings : Frame::Settings, **_kwargs)
      params = settings.params

      # oh god the namespacing here is probably gonna be too much
      if params.has_key? Frame::Settings::Parameter::EnablePush
        @push_enabled = params[Frame::Settings::Parameter::EnablePush] != 0
      end

      if params.has_key?(Frame::Settings::Parameter::InitialWindowSize)
        @window_size = params[Frame::Settings::Parameter::InitialWindowSize]
      end

      send Frame::Settings.ack(settings) unless settings.ack?
    end

    enum State
      Idle
      ReservedLocal
      ReservedRemote
      Open
      HalfClosedLocal
      HalfClosedRemote
      Closed
    end
  end
end
