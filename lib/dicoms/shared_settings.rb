require 'yaml'
require 'json'

class DicomS

  # Shared Settings are Settings stored in a SharedFile so
  # they can be used concurrently from different processes.
  class SharedSettings
    def initialize(name, options = {})
      @file = SharedFile.new(name)
      @format = options[:format]
      @compact = options[:compact]
      unless @format
        if File.extname(@file.name) == '.json'
          @format = :json
        else
          @format = :yaml
        end
      end
      contents = options[:initial_contents]
      if contents && !@file.exists?
        # Create with given initial contents
        write contents
      end
      contents = options[:replace_contents]
      write contents if contents
    end

    # Read a shared file and obtain a Settings object
    #
    #     counter = shared_settings.read.counter
    #
    def read
      decode @file.read
    end

    # To make sure contents are not changed between reading and writing
    # use update:
    #
    #     shared_settings.update do |data|
    #       # modify data and return modified data
    #       data.counter += 1
    #       data
    #     end
    #
    def update(&blk)
      @file.update do |data|
        encode blk.call(decode(data))
      end
    end

    # Use this only if the contents written is independet of
    # the previous content (i.e. no need to read, the change the data
    # and write it back)
    #
    #     shared_settings.write Setting[counter: 0
    #
    def write(data)
      @file.write encode(data)
    end

    private

    def encode(data)
      case @format
      when :json
        if data.is_a?(Settings)
          if @compact
            data.to_h.to_json
          else
            JSON.pretty_generate(data)
          end
        else
          data.to_json
        end
      when :yaml
        data.to_yaml
      end
    end

    def decode(data)
      case @format
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
