class DicomS
  class Progress
    def initialize(description, options={})
      filename = options[:progress]
      # TODO: if filename == :console, show progress on the console
      if filename
        @file = SharedSettings.new(
          filename,
          replace_contents: {
            process: description,
            subprocess: options[:subprocess],
            progress: options[:initial_progress] || 0
          }
        )
      else
        @file = nil
      end
      @progress = 0
      @subprocess_start = @subprocess_size = @subprocess_percent = nil
    end

    attr_reader :progress

    def finished?
      @progress >= 100
    end

    def update(value, subprocess = nil)
      @progress = value
      if @file
        @file.update do |data|
          data.progress = @progress
          data.subprocess = subprocess if subprocess
          data
        end
      end
    end

    def finish
      update 100, 'finished'
    end

    # Begin a subprocess which represent `percent`
    # of the total process. The subprocess will be measured
    # with values up to `size`
    def begin_subprocess(description, percent=nil, size=0)
      end_subprocess if @subprocess_start
      @subprocess_start = @progress
      percent ||= 100
      if percent < 0
        # interpreted as percent of what's lef
        percent = (100 - @progress)*(-percent)/100.0
      end
      percent = [percent, 100 - @progress].min
      # @subprocess_end = @progress + percent
      @subprocess_size = size.to_f
      @subprocess_percent = percent
      update @progress, description
    end

    def update_subprocess(value)
      raise "Subprocess not started" unless @subprocess_start
      sub_fraction = value/@subprocess_size
      @progress = @subprocess_start + @subprocess_percent*sub_fraction
      if @subprocess_size < 20 || (value % 10) == 0
        # frequently updated processes don't update the file every
        # fime to avoid the overhead (just 1 in 10 times)
        update @progress
      end
    end

    def end_subprocess
      raise "Subprocess not started" unless @subprocess_start
      @progress = @subprocess_start + @subprocess_percent
      @subprocess_start = @subprocess_size = @subprocess_percent = nil
      update @progress
    end
  end
end
