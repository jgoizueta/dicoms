require 'thor'

class DicomS
  class CLI < Thor
    check_unknown_options!

    def self.exit_on_failure?
      true
    end

    desc 'version', "Display DicomS version"
    map %w(-v --version) => :version
    def version
      say "dicoms #{VERSION}"
    end

    class_option 'verbose', type: :boolean, default: false
    class_option 'settings', type: :string, desc: 'settings (read-only) file'
    class_option 'settings_io', type: :string, desc: 'settings file'

    desc "pack DICOM-DIR", "pack a DICOM directory"
    option :output,   desc: 'output file', aliases: '-o'
    option :tmp,      desc: 'temporary directory'
    option :transfer,   desc: 'transfer method', aliases: '-t', default: 'sample'
    option :center,     desc: 'center (window transfer)', aliases: '-c'
    option :width,      desc: 'window (window transfer)', aliases: '-w'
    option :ignore_min, desc: 'ignore minimum (global/first/sample transfer)', aliases: '-i'
    option :samples,    desc: 'number of samples (sample transfer)', aliases: '-s'
    option :min,   desc: 'minimum value (fixed transfer)'
    option :max,   desc: 'maximum value (fixed transfer)'
    option :reorder, desc: 'reorder slices based on instance number'
    def pack(dicom_dir)
      DICOM.logger.level = Logger::FATAL
      strategy_parameters = {
        ignore_min: true
      }
      settings = {} # TODO: ...
      unless File.directory?(dicom_dir)
        raise Error, set_color("Directory not found: #{dicom_dir}", :red)
        say options
      end
      cmd_options = CommandOptions[
        settings: options.settings,
        settings_io: options.settings_io,
        output: options.output,
        tmp:  options.tmp,
        reorder: options.reorder,
        dicom_metadata: true
      ]
      packer = DicomS.new(settings)
      packer.pack dicom_dir, cmd_options
      # rescue => raise Error?
      0
    end

    desc "unpack dspack", "unpack a dspack file"
    option :output,   desc: 'output directory', aliases: '-o'
    option :dicom,    desc: 'dicom format output directory', aliases: '-d'
    # TODO: parameters for dicom regeneration
    def unpack(dspack)
      DICOM.logger.level = Logger::FATAL
      unless File.file?(dspack)
        raise Error, set_color("File not found: #{dspack}", :red)
        say options
      end
      settings = {} # TODO: ...
      packer = DicomS.new(settings)
      packer.unpack(
        dspack,
        settings: options.settings,
        settings_io: options.settings_io,
        output: options.output,
        dicom_output: options.dicom
      )
      # rescue => raise Error?
      0
    end

    desc "extract DICOM-DIR", "extract images from a set of DICOM files"
    option :output,   desc: 'output directory', aliases: '-o'
    option :transfer,   desc: 'transfer method', aliases: '-t', default: 'window'
    option :center,     desc: 'center (window transfer)', aliases: '-c'
    option :width,      desc: 'window (window transfer)', aliases: '-w'
    option :ignore_min, desc: 'ignore minimum (global/first/sample transfer)', aliases: '-i'
    option :samples,    desc: 'number of samples (sample transfer)', aliases: '-s'
    option :min,   desc: 'minimum value (fixed transfer)'
    option :max,   desc: 'maximum value (fixed transfer)'
    option :raw,   desc: 'generate raw output', aliases: '-r'
    option :big, desc: 'big-endian raw output'
    option :little, desc: 'little-endian raw output'
    def extract(dicom_dir)000
      DICOM.logger.level = Logger::FATAL
      settings = {} # TODO: ...
      unless File.exists?(dicom_dir)
        raise Error, set_color("Directory not found: #{dicom_dir}", :red)
        say options
      end

      raw = options.raw
      if options.big
        raw = true
        big_endian = true
      elsif options.little
        raw = true
        little_endian = true
      end

      packer = DicomS.new(settings)
      packer.extract(
        dicom_dir,
        transfer: DicomS.transfer_options(options),
        output: options.output,
        raw: raw, big_endian: big_endian, little_endian: little_endian
      )
      # rescue => raise Error?
      0
    end

    desc "Level stats", "Level limits of one or more DICOM files"
    def stats(dicom_dir)
      DICOM.logger.level = Logger::FATAL
      settings = {} # TODO: ...
      dicoms = DicomS.new(settings)
      stats = dicoms.stats dicom_dir
      puts "Aggregate values for #{stats[:n]} DICOM files:"
      puts "  Minimum level: #{stats[:min]}"
      puts "  Next minimum level: #{stats[:next_min]}"
      puts "  Maximum level: #{stats[:max]}"
      puts "Histogram:"
      dicoms.print_histogram *stats[:histogram], compact: true
      0
    end

    desc "Histogram", "Histogram of one or more DICOM files"
    option :width,   desc: 'bin width', aliases: '-w'
    option :compact,   desc: 'compact format', aliases: '-c'
    def histogram(dicom_dir)
      DICOM.logger.level = Logger::FATAL
      settings = {} # TODO: ...
      dicoms = DicomS.new(settings)
      width = options.width && options.width.to_f
      compact = !!options.compact
      dicoms.histogram dicom_dir, bin_width: width, compact: compact
      0
    end

    desc "Information", "Show DICOM metadata"
    option :output,   desc: 'output directory or file', aliases: '-o'
    def info(dicom_dir)
      DICOM.logger.level = Logger::FATAL
      settings = {} # TODO: ...
      dicoms = DicomS.new(settings)
      dicoms.info dicom_dir, output: options.output
      0
    end

    desc "projection DICOM-DIR", "extract projected images from a DICOM sequence"
    option :output,   desc: 'output directory', aliases: '-o'
    option :axial,    desc: 'N for single slice, * all, C center, mip or aap for volumetric aggregation'
    option :sagittal, desc: 'N for single slice, * all, C center, mip or aap for volumetric aggregation'
    option :coronal,  desc: 'N for single slice, * all, C center, mip or aap for volumetric aggregation'
    option :transfer,   desc: 'transfer method', aliases: '-t', default: 'window'
    # option :byte,       desc: 'transfer as bytes', aliases: '-b'
    option :center,     desc: 'center (window transfer)', aliases: '-c'
    option :width,      desc: 'window (window transfer)', aliases: '-w'
    option :ignore_min, desc: 'ignore minimum (global/first/sample transfer)', aliases: '-i'
    option :samples,    desc: 'number of samples (sample transfer)', aliases: '-s'
    option :min,   desc: 'minimum value (fixed transfer)'
    option :max,   desc: 'maximum value (fixed transfer)'
    option :max_x_pixels, desc: 'maximum number of pixels in the X direction'
    option :max_y_pixels, desc: 'maximum number of pixels in the Y direction'
    option :max_z_pixels, desc: 'maximum number of pixels in the Z direction'
    option :reorder, desc: 'reorder slices based on instance number'
    def projection(dicom_dir)
      DICOM.logger.level = Logger::FATAL
      settings = {} # TODO: ...
      unless File.directory?(dicom_dir)
        raise Error, set_color("Directory not found: #{dicom_dir}", :red)
        say options
      end
      if options.settings_io || options.settings
        cmd_options = CommandOptions[
          settings: options.settings,
          settings_io: options.settings_io,
          output: options.output,
          max_x_pixels: options.max_x_pixels && options.max_x_pixels.to_i,
          max_y_pixels: options.max_y_pixels && options.max_y_pixels.to_i,
          max_z_pixels: options.max_z_pixels && options.max_z_pixels.to_i,
          reorder: options.reorder,
        ]
      else
        cmd_options = CommandOptions[
          transfer: DicomS.transfer_options(options),
          output: options.output,
          axial: options.axial == 'axial' ? 'mip' : options.axial,
          sagittal: options.sagittal == 'sagittal' ? 'mip' : options.sagittal,
          coronal: options.coronal == 'coronal' ? 'mip' : options.coronal,
          max_x_pixels: options.max_x_pixels && options.max_x_pixels.to_i,
          max_y_pixels: options.max_y_pixels && options.max_y_pixels.to_i,
          max_z_pixels: options.max_z_pixels && options.max_z_pixels.to_i,
          reorder: options.reorder,
        ]
      end
      unless cmd_options.axial || options.sagittal || options.coronal
        raise Error, "Must specify at least one projection (axial/sagittal/coronal)"
      end
      packer = DicomS.new(settings)
      packer.projection(dicom_dir, cmd_options)
      # rescue => raise Error?
      0
    end

    desc "explode DICOM-DIR", "extract all projected images from a DICOM sequence"
    option :output,   desc: 'output directory', aliases: '-o'
    option :transfer,   desc: 'transfer method', aliases: '-t', default: 'window'
    # TODO: add :mip_transfer
    # option :byte,       desc: 'transfer as bytes', aliases: '-b'
    option :center,     desc: 'center (window transfer)', aliases: '-c'
    option :width,      desc: 'window (window transfer)', aliases: '-w'
    option :ignore_min, desc: 'ignore minimum (global/first/sample transfer)', aliases: '-i'
    option :samples,    desc: 'number of samples (sample transfer)', aliases: '-s'
    option :min,   desc: 'minimum value (fixed transfer)'
    option :max,   desc: 'maximum value (fixed transfer)'
    option :max_x_pixels, desc: 'maximum number of pixels in the X direction'
    option :max_y_pixels, desc: 'maximum number of pixels in the Y direction'
    option :max_z_pixels, desc: 'maximum number of pixels in the Z direction'
    option :reorder, desc: 'reorder slices based on instance number'
    def explode(dicom_dir)
      DICOM.logger.level = Logger::FATAL
      settings = {} # TODO: ...
      unless File.directory?(dicom_dir)
        raise Error, set_color("Directory not found: #{dicom_dir}", :red)
        say options
      end
      if options.settings_io || options.settings
        cmd_options = CommandOptions[
          settings: options.settings,
          settings_io: options.settings_io,
          output: options.output,
          max_x_pixels: options.max_x_pixels && options.max_x_pixels.to_i,
          max_y_pixels: options.max_y_pixels && options.max_y_pixels.to_i,
          max_z_pixels: options.max_z_pixels && options.max_z_pixels.to_i,
          reorder: options.reorder,
        ]
      else
        cmd_options = CommandOptions[
          transfer: DicomS.transfer_options(options),
          output: options.output,
          max_x_pixels: options.max_x_pixels && options.max_x_pixels.to_i,
          max_y_pixels: options.max_y_pixels && options.max_y_pixels.to_i,
          max_z_pixels: options.max_z_pixels && options.max_z_pixels.to_i,
          reorder: options.reorder,
        ]
      end
      packer = DicomS.new(settings)
      packer.explode(dicom_dir, cmd_options)
      # rescue => raise Error?
      0
    end

    desc "Remap DICOM-DIR", "convert DICOM pixel values"
    option :output,     desc: 'output directory', aliases: '-o'
    option :transfer,   desc: 'transfer method', aliases: '-t', default: 'identity'
    option :unsigned,   desc: 'transfer as unsigned', aliases: '-u'
    # option :byte,       desc: 'transfer as bytes', aliases: '-b'
    option :center,     desc: 'center (window transfer)', aliases: '-c'
    option :width,      desc: 'window (window transfer)', aliases: '-w'
    option :ignore_min, desc: 'ignore minimum (global/first/sample transfer)', aliases: '-i'
    option :samples,    desc: 'number of samples (sample transfer)', aliases: '-s'
    option :min,   desc: 'minimum value (fixed transfer)'
    option :max,   desc: 'maximum value (fixed transfer)'
    def remap(dicom_dir)
      DICOM.logger.level = Logger::FATAL
      settings = {} # TODO: ...
      unless File.directory?(dicom_dir)
        raise Error, set_color("Directory not found: #{dicom_dir}", :red)
        say options
      end
      packer = DicomS.new(settings)
      packer.remap(
        dicom_dir,
        transfer: DicomS.transfer_options(options),
        output: options.output
      )
      # rescue => raise Error?
      0
    end
  end

  class <<self
    def transfer_options(options)
      strategy = options.transfer.to_sym
      params = {}
      params[:output] = :unsigned if options.unsigned
      params[:output] = :byte     if options.byte
      params[:center] = options.center.to_f if options.center
      params[:width] = options.width.to_f if options.width
      if options.ignore_min
        params[:ignore_min] = true
      elsif [:global, :first, :sample].include?(strategy)
        params[:ignore_min] = false
      end
      params[:max_files] = options.samples if options.samples
      params[:min] = options[:min].to_f if options[:min]
      params[:max] = options[:max].to_f if options[:max]

      if params.empty?
        strategy
      else
        [strategy, params]
      end
    end
  end
end
