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
      if data.is_a?(Settings) || data.is_a?(Hash)
        # Specially for YAML, we don't want to use symbols for
        # hash keys because if read with languages other than
        # Ruby that may cause some troubles.
        data = stringify_keys(data.to_h)
      end
      case @format
      when :json
        if @compact
          JSON.dump data
        else
          JSON.pretty_generate data
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

    # Convert symbolic keys to strings in a hash recursively
    def stringify_keys(data)
      if data.is_a?(Hash)
        Hash[
          data.map do |k, v|
            [k.respond_to?(:to_sym) ? k.to_s : k, stringify_keys(v)]
          end
        ]
      else
        data
      end
    end
  end

end
