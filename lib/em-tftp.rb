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
# - test against ~3 other implementations

require 'eventmachine'
require 'socket'

module TFTP

  Error = Class.new(Exception)

  module Protocol
    ERROR_MESSAGES = {
      0 => "Unknown error",
      1 => "File not found",
      2 => "Access violation",
      3 => "Disk full or allocation exceeded",
      4 => "Illegal TFTP operation",
      5 => "Unknown transfer ID",
      6 => "File already exists",
      7 => "No such user"}

    # Used to decode incoming packets
    # TFTP packets have a simple structure: the port number from the encapsulating UDP datagram doubles as a 'transfer ID',
    #   allowing multiple, simultaneous transfers betweent the same hosts
    # The first 2 bytes of the payload are an integral 'opcode' from 1-5, in network byte order
    # The opcodes are: Read ReQuest, Write ReQuest, DATA, ACK, and ERROR
    # Depending on the opcode, different fields can follow. All fields are either 16-bit integers in network byte order,
    #   or null-terminated strings
    class Packet
      OPCODES = {1 => :rrq, 2 => :wrq, 3 => :data, 4 => :ack, 5 => :error}

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
          raise TFTP::Error, "Unknown TFTP packet type (opcode #{data.getbyte(1)})"
        end
      end

      attr_reader :opcode, :filename, :block_no, :data
    end

    private

    def send_rrq(addr=@peer_addr, port=@peer_port, filename)
      data = "\0\1" << filename << "\0octet\0"
      send_packet(addr, port, data)
    end
    def send_wrq(addr=@peer_addr, port=@peer_port, filename)
      data = "\0\2" << filename << "\0octet\0"
      send_packet(addr, port, data)
    end
    def send_block(addr=@peer_addr, port=@peer_port, buffer, pos, block_no)
      block = buffer.slice(pos, 512) || ""
      data = "\0\3" << ((block_no >> 8) & 255) << (block_no & 255) << block
      send_packet(data)
      pos + 512
    end
    def send_ack(addr=@peer_addr, port=@peer_port, block_no)
      data = "\0\4" << ((block_no >> 8) & 255) << (block_no & 255)
      send_packet(addr, port, data)
    end
    def send_error(addr=@peer_addr, port=@peer_port, code, msg)
      data = "\0\5" << ((code >> 8) & 255) << (code & 255) << msg << "\0"
      send_packet(addr, port, data)
    end
    def send_packet(addr=@peer_addr, port=@peer_port, data)
      # this appears useless, but is intended to be overridden
      $stderr.puts "Sending: #{data} (#{data[0..3].bytes.to_a.join(',')}) to #{addr}:#{port}"  if $DEBUG
      send_datagram(data, addr, port)
    end
  end

  # An in-progress file transfer operation
  # Holds all the state which a TFTP server/client needs to track for a single transfer
  # Subclasses contain logic specific to client downloads, server downloads, client uploads, server uploads
  class Transfer
    include Protocol

    BASE_RETRANSMIT_TIMEOUT = 1.5 # seconds
    MAX_RETRANSMIT_TIMEOUT = 12

    def initialize(connection, peer_addr, peer_port, listener)
      # 'connection' is the UDP socket used for this transfer (actually an EventMachine::Connection object)
      # each transfer uses a newly opened UDP socket, which is closed after the transfer is finished
      # this is because the UDP port number doubles as a TFTP transfer ID
      # so using the same port number for 2 successive requests to the same peer may cause problems
      @connection = connection
      @peer_addr, @peer_port, @listener = peer_addr, peer_port, listener
      @buffer = @block_no = @timer = nil
      @timeout = 1.5
    end

    attr_reader :peer_addr, :peer_port
    attr_accessor :buffer, :block_no, :timer, :timeout

    # Abort the file transfer. An optional error message and code can be included.
    # This should be called if the transfer cannot be completed due to a full hard disk, wrong permissions, etc
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
    def abort!(code=0, error_msg=Protocol::ERROR_MESSAGES[code])
      stop_timer!
      send_error(code, error_msg || "Unknown error")
      @connection.close_connection_after_writing
      @listener.failed(error_msg || "Unknown error")
    end

    private

    def stop_timer!
      if @timer
        @timer.cancel
        @timer = nil
      end
      @timeout = BASE_RETRANSMIT_TIMEOUT
    end
    def set_timer!(data)
      @timer = EM::Timer.new(@timeout) do
        @timeout *= 2
        if @timeout <= MAX_RETRANSMIT_TIMEOUT
          send_packet(data)
        else
          abort!(0, "Connection timed out")
        end
      end
    end

    def finished!
      stop_timer!
      @connection.close_connection
      @listener.completed
    end

    def send_packet(addr=@peer_addr, port=@peer_port, packet_data)
      $stderr.puts "Sending: #{packet_data} (#{packet_data[0..3].bytes.to_a.join(',')}) to #{addr}:#{port}" if $DEBUG
      @connection.send_datagram(packet_data, addr, port)
      set_timer!(packet_data) unless packet_data.start_with? "\0\5" # no timeout and retransmit for error packets
    end

    def rrq(packet, port)
      # a transfer has already started and is not yet finished
      # a RRQ/WRQ shouldn't arrive at this time
      abort!(4, "Received unexpected TFTP RRQ packet")
    end
    def wrq(packet, port)
      abort!(4, "Received unexpected TFTP WRQ packet")
    end
  end

  class Receive < Transfer
    # Receive a file from the peer
    def initialize(connection, peer_addr, peer_port, listener)
      super(connection, peer_addr, peer_port, listener)
      @buffer = ""
      @block_no = 1
    end

    def data(packet, port)
      if packet.block_no == @block_no
        stop_timer!
        if @peer_port.nil?
          @peer_port = port
        end
        if packet.data.size > 0
          @listener.received_block(packet.data)
        end
        if packet.data.size < 512
          finished!
        else
          send_ack(@block_no)
          @block_no += 1
        end
      end
    end
    def ack(packet, port)
      abort!(4, "Received unexpected TFTP ACK packet while receiving file")
    end
  end

  class ClientReceive < Receive
    def initialize(connection, peer_addr, listener, filename)
      super(connection, peer_addr, nil, listener)
      send_rrq(peer_addr, 69, filename)
    end
  end

  class ServerReceive < Receive
    def initialize(connection, peer_addr, peer_port, listener)
      super(connection, peer_addr, peer_port, listener)
      send_ack(0)
    end
  end

  class Send < Transfer
    # Send a file to the peer
    # Note that the file data does not necessarily have to originate from the filesystem;
    #   it could be cached in memory or generated dynamically
    def initialize(connection, peer_addr, peer_port, listener, file_data)
      super(connection, peer_addr, peer_port, listener)
      @buffer = file_data
    end

    def ack(packet, port)
      if packet.block_no == @block_no
        stop_timer!
        if @peer_port.nil?
          @peer_port = nil
        end
        @block_no += 1
        if @buffer.size <= 512
          @pos = send_block(@buffer, @pos, @block_no)
          finished!
        else
          @pos = send_block(@buffer, @pos, @block_no)
        end
      end
    end
    def data(packet, port)
      abort!(4, "Received unexpected TFTP DATA packet while sending file")
    end
  end

  class ClientSend < Send
    def initialize(connection, peer_addr, listener, filename, file_data)
      super(connection, peer_addr, nil, listener, file_data)
      # we need to send a WRQ and get an ACK before sending
      @block_no = 0
      @pos = 0
      send_wrq(peer_addr, 69, filename)
    end
  end

  class ServerSend < Send
    def initialize(connection, peer_addr, peer_port, listener, file_data)
      super(connection, peer_addr, peer_port, listener, file_data)
      # we have already received a RRQ, we can send to the peer immediately
      @block_no = 1
      @pos = send_block(@buffer, 0, @block_no)
    end
  end

  def self.ListeningConnection(listener_klass)
    # create a subclass of ListeningConnection which uses a specific type of listener
    # this is necessary because when opening a socket, EM does not take a connection OBJECT argument, but a connection CLASS
    Class.new(TFTP::ListeningConnection).tap { |c| c.instance_variable_set(:@listener_klass, listener_klass) }
  end

  # UDP socket (really EM::Connection) on TFTP server which waits for incoming RRQ/WRQ
  # When an incoming transfer request arrives, calls get/put on its listener
  #   and starts the transfer if get passes true,<file data> (or put passes true) to the block
  # If the data must be read from hard disk, EM.defer { File.read(...) } is recommended,
  #   so as not to block the EM reactor from handling events
  class ListeningConnection < EM::Connection
    include Protocol

    def listener
      self.class.instance_eval { @listener_klass }
    end

    def receive_data(data)
      peer_port, peer_addr = Socket.unpack_sockaddr_in(get_peername)
      $stderr.puts "Received: #{data} (#{data[0..3].bytes.to_a.join(',')}) from #{peer_addr}:#{peer_port}" if $DEBUG
      packet = Packet.new(data.encode!(Encoding::BINARY))
      send(packet.opcode, peer_addr, peer_port, packet)
    rescue TFTP::Error
      if listener.respond_to?(:error)
        listener.error($!.message)
      end
    end

    private

    def rrq(addr, port, packet)
      listener.get(addr, port, packet.filename) do |aye_nay, str_data|
        if aye_nay
          connection = EM.open_datagram_socket('0.0.0.0', 0, TFTP::TransferConnection)
          connection.transfer = ServerSend.new(connection, addr, port, listener.new, str_data)
        else
          send_error(addr, port, 0, str_data || "Denied")
        end
      end
    end

    def wrq(addr, port, packet)
      listener.put(addr, port, packet.filename) do |aye_nay, str_data|
        if aye_nay
          connection = EM.open_datagram_socket('0.0.0.0', 0, TFTP::TransferConnection)
          connection.transfer = ServerReceive.new(connection, addr, port, listener.new)
        else
          send_error(addr, port, 0, "Denied")
        end
      end
    end

    def data(addr, port, packet)
      send_error(addr, port, 5, "Unknown transfer ID")
    end
    def ack(addr, port, packet)
      # It's not a good idea to send an error back for unexpected ACK;
      # some TFTP clients may send an "eager" ACK to try to make file come faster
    end
  end

  # UDP socket (really EM::Connection) which is being used for an in-progress transfer
  class TransferConnection < EM::Connection
    include Protocol

    attr_accessor :transfer

    def receive_data(data)
      peer_port, peer_addr = Socket.unpack_sockaddr_in(get_peername)
      $stderr.puts "Received: #{data} (#{data[0..3].bytes.to_a.join(',')}) from #{peer_addr}:#{peer_port}" if $DEBUG
      packet = Packet.new(data.encode!(Encoding::BINARY))
      if transfer && peer_addr == transfer.peer_addr && (peer_port == transfer.peer_port || transfer.peer_port.nil?)
        transfer.send(packet.opcode, packet, peer_port)
      end
    end
  end

  # Listeners

  class ClientUploader
    def initialize(&block)
      @callback = block
    end
    def completed
      @callback.call(true, nil)
    end
    def failed(error_msg)
      @callback.call(false, error_msg)
    end
  end

  class ClientDownloader
    def initialize(&block)
      @callback = block
      @buffer = ""
    end
    def received_block(block)
      @buffer << block
    end
    def completed
      @callback.call(true, @buffer)
    end
    def failed(error_msg)
      @callback.call(false, error_msg)
    end
  end

  def self.ReadOnlyFileServer(base_dir)
    Class.new(ReadOnlyFileServer).tap { |c| c.instance_variable_set(:@base_dir, base_dir) }
  end

  class ReadOnlyFileServer
    def self.get(addr, port, filename, &block)
      filename.slice!(0) if filename.start_with?('/')
      begin
        path = File.join(@base_dir, filename)
        if File.exist?(path)
          EventMachine.defer(proc { File.binread(path) }, proc { |file_data| block.call(true, file_data) })
        else
          block.call(false, "File not found")
        end
      rescue
        block.call(false, $!.message)
      end
    end

    def self.put(addr, port, filename)
      yield false
    end

    def completed
      # log?
    end
    def failed(error_msg)
      # log?
    end

    private

    def base_dir
      self.class.instance_eval { @base_dir }
    end
  end
end

module EventMachine
  class << self
    def start_tftp_server(server='0.0.0.0', port=69, listener_klass)
      if !listener_klass.is_a?(Class)
        if listener_klass.is_a?(Module)
          listener_klass = Class.new.tap { include listener_klass }
        else
          raise ArgumentError, "Expected a class which defines callback methods like #received_block, #completed, and #failed; got #{listener_klass.class} instead"
        end
      end

      EM.open_datagram_socket(server, port, TFTP::ListeningConnection(listener_klass))
    end

    def tftp_get(server, port=69, filename, &callback)
      conn = EM.open_datagram_socket('0.0.0.0', 0, TFTP::TransferConnection)
      conn.transfer = TFTP::ClientReceive.new(conn, server, TFTP::ClientDownloader.new(&callback), filename)
    end

    def tftp_put(server, port=69, filename, file_data, &callback)
      conn = EM.open_datagram_socket('0.0.0.0', 0, TFTP::TransferConnection)
      if file_data.is_a?(IO)
        EventMachine.defer(proc { file_data.read }, proc { |data| conn.transfer = TFTP::ClientSend.new(conn, server, port, TFTP::ClientUploader.new(&callback), filename, data) })
      else
        conn.transfer = TFTP::ClientSend.new(conn, server, TFTP::ClientUploader.new(&callback), filename, file_data)
      end
    end
  end
end