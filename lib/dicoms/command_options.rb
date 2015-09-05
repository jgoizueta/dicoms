class DicomS
  class CommandOptions < Settings
    def initialize(options)
      @base_dir = nil
      if settings_file = options.delete(:settings_io)
        @settings_io = SharedSettings.new(settings_file)
      else
        settings_file = options.delete(:settings)
      end
      if settings_file
        settings = SharedSettings.new(settings_file).read
        options = settings.merge(options.to_h.reject{ |k, v| v.nil? })
        @base_dir = File.dirname(settings_file)
      else
        @base_dir = nil
      end
      super options
    end

    def path_option(option, default = nil)
      path = self[option.to_sym] || default
      path = File.expand_path(path, @base_dir) if @base_dir && path
      path
    end

    attr_reader :base_name

    def self.[](options)
      options.is_a?(CommandOptions) ? options : CommandOptions.new(options)
    end

    def save_settings(command, data)
      if @settings_io
        @settings_io.update do |settings|
          settings.merge command.to_sym => data
        end
      end
    end
  end
end
