class DicomPack
  class Progress
    def initialize(description, options={})
      filename = options[:progress]
      if filename
        @file = SharedFile.new(
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
      update @progress
    end

    def end_subprocess
      raise "Subprocess not started" unless @subprocess_start
      @progress = @subprocess_start + @subprocess_percent
      @subprocess_start = @subprocess_size = @subprocess_percent = nil
      update @progress
    end
  end
end
