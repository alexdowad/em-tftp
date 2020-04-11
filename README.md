EM-TFTP
=======

EM-TFTP is a Ruby EventMachine-based implementation of the TFTP protocol (both client and server sides).

TFTP Server API
---------------

To run a TFTP server, first you need to define an event handler class which will be used to customize how EM-TFTP handles client requests. One instance of the class will be created for each file transfer operation (so you can store values related to each individual operation in instance variables).

Code says it clearer than prose:

```ruby
class MyTFTPServer
  def self.get(client_addr, client_port, filename)
    # if you want to accept a file read request and send back a file:
    yield true, "put the file contents here"
    
    # note that the data doesn't have to be read from disk; it could be cached in memory,
    #   stored in a database, generated dynamically, etc.

    # if you want to reject a file read request:
    yield false, "error message here"
  end

  def self.put(client_addr, client_port, filename)
    # same deal, if you want to accept a file write request:
    yield true
    # or if not:
    yield false
  end

  def self.error(error_msg)
    # this one is optional -- it will be called if an error occurs when establishing
    #   a new file transfer operation
  end

  def received_block(str)
    # when a file write request is accepted, an instance of this class will be created
    #   and this method will be called for EACH block of data which is received

    # you can either write it to disk or do anything else you want with it
    # in some cases you may want to buffer it and use in in #completed, below
  end

  def completed
    # callback when a read/write request finishes successfully...
  end

  def failed(error_msg)
    # callback when it doesn't
  end
end
```

With your event handler class defined, you just need:

```ruby
# the default UDP port for TFTP servers is 69
EM.run { EM.start_tftp_server('0.0.0.0', 69, MyTFTPServer) }
```

TFTP Client API
---------------

Even simpler:

```ruby
EM.run do
  EM.tftp_get(server_ip, 69, 'some-file-name.txt') do |success, content|
    if success
      # do something with the file content
    else
      # if not successful, 'content' will be an error message
    end
  end

  EM.tftp_put(server_ip, 69, 'another-file-name.txt', 'FILE CONTENTS') do |success, err_msg|
    # likewise
  end
end
```

Warnings:
---------

- In most cases, EM-TFTP requires you to buffer entire files in memory when sending/receiving. This will not work well for huge files. On the other hand, TFTP is not designed for transferring huge files.
