require 'yaml'
require 'json'

class DicomPack

  # Shared files can be concurrently accessed by diferent processes.
  # They should never be large files, and update operations (reading,
  # then writing) should always be quick, because processes trying to
  # read the file while an update is going on are blocked.
  #
  # They contents of a ShareFile is a Settings object.
  #
  class SharedFile
    def initialize(name, options = {})
      @name = name
      raise "A directory exists with that name" if File.directory?(@name)
      @format = options[:format] || :json
      contents = options[:initial_contents]
      if contents && !exists?
        # Create with given initial contents
        write contents
      end
      contents = options[:replace_contents]
      write contents if contents
    end

    def exists?
      File.exists?(@name)
    end

    # Read a shared file and obtain a Settings object
    #
    #     counter = shared_file.read.counter
    #
    def read
      data = SharedFile.read(@name)
      SharedFile.decode(data, @format)
    end

    # To make sure contents are not changed between reading and writing
    # use update:
    #
    #     shared_file.update do |data|
    #       # modify data and return modified data
    #       data.counter += 1
    #       data
    #     end
    #
    def update(&blk)
      SharedFile.update(@name) do |data|
        data = blk.call(SharedFile.decode(data, @format))
        SharedFile.encode(data, @format)
      end
    end

    # Use this only if the contents written is independet of
    # the previous content (i.e. no need to read, the change the data
    # and write it back)
    #
    #     shared_file.write Setting[counter: 0
    #
    def write(data)
      data = SharedFile.encode(data, @format)
      SharedFile.write(@name, data)
    end

    private

    # Low level file handling
    class <<self
      #  Update a file safely. The block
      #
      # Example
      #
      #    SharedFile.update 'counter' do |contents|
      #      contents.to_i + 1
      #    end
      #
      #    counter = read_shared_file('counter').to_i
      #
      def update(filename, &blk)
        File.open(filename, File::RDWR|File::CREAT, 0644) do |file|
          file.flock File::LOCK_EX
          if blk.arity == 1
            new_contents = blk.call(file.read)
          else
            new_contents = blk.call
          end
          file.rewind
          file.write new_contents
          file.flush
          file.truncate file.pos
        end
      end

      #  Read a file safely
      #
      # Example
      #
      #    counter = SharedFile.read('counter').to_i
      #
      def read(filename)
        File.open(filename, "r") do |file|
          file.flock File::LOCK_SH # this blocks until available
          file.read
        end
      end

      def write(filename, contents)
        update(filename) { contents }
      end

      def encode(data, format)
        case format
        when :json
          if data.is_a?(Settings)
            data.to_h.to_json
          else
            data.to_json
          end
        when :yaml
          data.to_yaml
        end
      end

      def decode(data, format)
        case format
        when :json
          data = JSON.load(data)
        when :yaml
          data = YAML.load(data)
        end
        if data.is_a?(Hash)
          Settings[data]
        else
          data
        end
      end
    end

  end

end
