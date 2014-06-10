# encoding: ASCII-8BIT
# EventMachine-based TFTP implementation
#
# References: RFC1350 (defines TFTP protocol)
#
# Caveats: em-tftp's ReadOnlyFileServer reads an entire file into memory before sending it
#   This will not work well for huge files. But then again, TFTP is not designed for transferring huge files

# TODO:
# - documentation
# - RDoc

require 'eventmachine'
require 'socket'

module TFTP
  class Connection < EM::Connection
    BASE_RETRANSMIT_TIMEOUT = 1.5 # seconds
    MAX_RETRANSMIT_TIMEOUT = 12

    # COMMANDS:

    # Abort the file transfer. An optional error message and code can be included.
    #
    # TFTP error codes include:
    #
    # 0         Not defined, see error message (if any).
    # 1         File not found.
    # 2         Access violation.
    # 3         Disk full or allocation exceeded.
    # 4         Illegal TFTP operation.
    # 5         Unknown transfer ID.
    # 6         File already exists.
    # 7         No such user.
    def abort(error_msg=nil, code=0)
      # this should be called if the disk is full, permissions do not allow the file to be read/saved, etc.
      send_error(code, error_msg || "Unknown error")
      close_connection
      closed!
    end

    # Send a file back to the client (in response to a 'get' request)
    # Note that the file data does not necessarily have to originate from the filesystem;
    #   it could be cached in memory or generated dynamically
    def send_file(file_data)
      @buffer = file_data
      @block_no = 1
      send_block
    end

    # CALLBACKS:

    def get(peer_address, port, filename)
      # call send if you want to send the file, or abort if not
    end

    def put(peer_address, port, filename)
      # call abort here if you do not want to accept file
    end

    def received_block(block)
    end

    def failed(error_msg=nil)
    end

    def completed
    end

    # DEFAULT CALLBACKS INVOKED BY EventMachine
    # Not intended to be overridden in subclasses

    def post_init
      @buffer = @direction = @block_no = nil
      @closed = false
      @timeout = 1.5
      @timer = nil
    end

    def receive_data(data)
      @peer_port, @peer_addr = Socket.unpack_sockaddr_in(get_peername)
      packet = Packet.new(data.encode!(Encoding::BINARY))
      send(packet.opcode, packet)
    rescue TFTP::Error
      close_connection
      closed!
      failed($!.message)
    end

    def unbind
      unless @closed
        closed!
        failed("Connection closed")
      end
    end

    private

    def rrq(packet)
      @direction = :send
      get(@peer_addr, @peer_port, packet.filename)
    end
    def wrq(packet)
      @direction = :receive
      @buffer = "".encode!(Encoding::BINARY)
      @block_no = 1
      put(@peer_addr, @peer_port, packet.filename)
    end
    def data(packet)
      raise "Received unexpected TFTP DATA packet while sending file" if @direction != :receive
      if packet.block_no == @block_no
        stop_timer!
        if packet.data.size > 0
          received_block(packet.data)
        end
        if packet.data.size < 512
          completed
        else
          send_ack
          @block_no += 1
        end
      end
    end
    def ack(packet)
      raise "Received unexpected TFTP ACK packet while receiving file" if @direction != :send
      stop_timer!
      if packet.block_no == @block_no
        @block_no += 1
        if @buffer.size <= 512
          send_block
          completed
        else
          send_block
        end        
      end
    end

    def send_block
      block = @buffer.slice!(0, 512)
      data = "\0\3" << ((@block_no >> 8) & 255) << (@block_no & 255) << block
      send_packet(data)
    end
    def send_ack
      data = "\0\4" << ((@block_no >> 8) & 255) << (@block_no & 255)
      send_packet(data)
    end
    def send_error(code, msg)
      data = "\0\5" << ((code >> 8) & 255) << (code & 255) << msg << "\0"
      send_packet(data, false)
    end
    def send_packet(data, set_timer=true)
      send_datagram(data, @peer_addr, @peer_port)
      set_timer!(data) if set_timer
    end

    def closed!
      @closed = true
      @direction = @buffer = @block_no = nil
      stop_timer!
    end
    def set_timer!(data)
      @timer = EM::Timer.new(@timeout) do
        @timeout *= 2
        if @timeout <= MAX_RETRANSMIT_TIMEOUT
          send_packet(data)
        end
      end
    end
    def stop_timer!
      if @timer
        @timer.cancel
        @timer = nil
        @timeout = BASE_RETRANSMIT_TIMEOUT
      end
    end
  end

  class ClientConnection < Connection
    def get_file(peer_addr, port, filename, &on_complete)
      @peer_addr, @peer_port, @callback = peer_addr, port, on_complete
      send_rrq(filename)
    end

    def put_file(peer_addr, port, filename, file_data, &on_complete)
      @peer_addr, @peer_port, @callback = peer_addr, port, on_complete
      @buffer = file_data
      send_wrq(filename)
    end

    def get(peer_address, port, filename)
      abort
    end
    def put(peer_address, port, filename)
      abort
    end

    def received_block(block)
      @buffer << block if @direction == :receive
    end

    def failed(error_msg=nil)
      @callback.call(:failed, error_msg)
    end
    def completed
      @callback.call(:success, @buffer)
    end

    private

    def send_rrq(filename)
      @buffer = "".encode!(Encoding::BINARY)
      @block_no = 1
      @direction = :receive
      data = "\0\1" << filename << "\0octet\0"
      send_datagram(data, @peer_addr, @peer_port)
    end
    def send_wrq(filename)
      @block_no = 0
      @direction = :send
      data = "\0\2" << filename << "\0octet\0"
      send_datagram(data, @peer_addr, @peer_port)
    end
  end

  def self.ReadOnlyFileServer(base_dir)
    base_dir << '/' unless base_dir.end_with?('/')
    klass = Class.new(TFTP::Connection)
    klass.send(:define_method, :get) do |peer_addr, port, filename|
      filename.slice!(0) if filename.start_with?('/')
      path = File.join(base_dir, filename)
      begin
        if File.exist?(path)
          EventMachine.defer(proc { File.binread(path) }, method(:send_file))
        else
          abort("File not found", 1)
        end
      rescue
        abort
      end
    end
    klass.send(:define_method, :put) { abort }
    klass
  end

  class Packet
    OPCODES = {1 => :rrq, 2 => :wrq, 3 => :data, 4 => :ack, 5 => :error}
    ERROR_MESSAGES = {
      0 => "Unknown error",
      1 => "File not found",
      2 => "Access violation",
      3 => "Disk full or allocation exceeded",
      4 => "Illegal TFTP operation",
      5 => "Unknown transfer ID", 
      6 => "File already exists", 
      7 => "No such user"}

    def initialize(data)
      raise TFTP::Error, "TFTP packet too small (#{data.size} bytes)" if data.size < 4
      raise TFTP::Error, "TFTP packet too large (#{data.size} bytes)" if data.size > 516
      @opcode = OPCODES[data.getbyte(1)]
      if opcode == :data
        @block_no = (data.getbyte(2) << 8) + data.getbyte(3)
        @data = data[4..-1]
      elsif opcode == :rrq || opcode == :wrq
        @filename, _mode = data[2..-1].unpack("Z*Z*") # mode is ignored
      elsif opcode == :error
        @err_code = (data.getbyte(2) << 8) + data.getbyte(3)
        @err_msg  = data[4..-2] # don't include null terminator
        if @err_msg.size == 0
          @err_msg = ERROR_MESSAGES[@err_code] || "Unknown error"
        end
        raise TFTP::Error, @err_msg
      elsif opcode == :ack
        @block_no = (data.getbyte(2) << 8) + data.getbyte(3)
      else
        raise TFTP::Error, "Unknown TFTP packet type (code #{data.getbyte(1)})"
      end
    end

    attr_reader :opcode, :filename, :block_no, :data
  end

  Error = Class.new(Exception)
end

module EventMachine
  class << self
    def start_tftp_server(server='0.0.0.0', port=69, handler)
      klass = if handler.is_a?(Class)
        raise "Expected a subclass of TFTP::Connection" unless TFTP::Connection > handler
        handler
      elsif handler.is_a?(Module)
        TFTP::Connection.new.tap { |c| c.extend handler }
      else
        raise "Expected a subclass of TFTP::Connection or a Module, got #{handler.class}"
      end

      EM.open_datagram_socket(server, port, klass)
    end

    def tftp_get(server, port, filename, &callback)
      conn = EM.open_datagram_socket('0.0.0.0', 0, TFTP::ClientConnection)
      conn.get_file(server, port, filename, &callback)
    end

    def tftp_put(server, port, filename, file_data, &callback)
      conn = EM.open_datagram_socket('0.0.0.0', 0, TFTP::ClientConnection)
      conn.put_file(server, port, filename, file_data, &callback)
    end
  end
end