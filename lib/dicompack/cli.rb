require 'thor'

class DicomPack
  class CLI < Thor
    check_unknown_options!

    def self.exit_on_failure?
      true
    end

    desc 'version', "Display dicompack version"
    map %w(-v --version) => :version
    def version
      say "dicompack #{VERSION}"
    end

    class_option 'verbose', type: :boolean, default: false

    desc "pack DICOM-DIR", "pack a DICOM directory"
    option :output,   desc: 'output file', aliases: '-o'
    option :tmp,      desc: 'temporary directory'
    option :transfer,   desc: 'transfer method', aliases: '-t', default: 'identity'
    option :center,     desc: 'center (window transfer)', aliases: '-c'
    option :width,      desc: 'window (window transfer)', aliases: '-w'
    option :ignore_min, desc: 'ignore minimum (global/first/sample transfer)', aliases: '-i'
    option :samples,    desc: 'number of samples (sample transfer)', aliases: '-s'
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
      packer = DicomPack.new(settings)
      packer.pack(
        dicom_dir,
        transfer: DicomPack.transfer_options(options),
        output: options.output,
        tmp:  options.tmp
      )
      # rescue => raise Error?
      0
    end

    desc "unpack DICOMPACK", "unpack a dicompack file"
    option :output,   desc: 'output directory', aliases: '-o'
    def unpack(dicompack)
      DICOM.logger.level = Logger::FATAL
      unless File.file?(dicompack)
        raise Error, set_color("File not found: #{dicompack}", :red)
        say options
      end
      settings = {} # TODO: ...
      packer = DicomPack.new(settings)
      packer.unpack dicompack
      # rescue => raise Error?
      0
    end

    desc "extract DICOM-DIR", "extract images from a set of DICOM files"
    option :output,   desc: 'output directory', aliases: '-o'
    option :transfer,   desc: 'transfer method', aliases: '-t', default: 'identity'
    option :center,     desc: 'center (window transfer)', aliases: '-c'
    option :width,      desc: 'window (window transfer)', aliases: '-w'
    option :ignore_min, desc: 'ignore minimum (global/first/sample transfer)', aliases: '-i'
    option :samples,    desc: 'number of samples (sample transfer)', aliases: '-s'
    def extract(dicom_dir)
      DICOM.logger.level = Logger::FATAL
      settings = {} # TODO: ...
      unless File.exists?(dicom_dir)
        raise Error, set_color("Directory not found: #{dicom_dir}", :red)
        say options
      end
      packer = DicomPack.new(settings)
      packer.extract(
        dicom_dir,
        transfer: DicomPack.transfer_options(options),
        output: options.output
      )
      # rescue => raise Error?
      0
    end

    desc "Level stats", "Level limits of one or more DICOM files"
    def stats(dicom_dir)
      DICOM.logger.level = Logger::FATAL
      settings = {} # TODO: ...
      dicompack = DicomPack.new(settings)
      stats = dicompack.stats dicom_dir
      puts "Aggregate values for #{stats[:n]} DICOM files:"
      puts "  Minimum level: #{stats[:min]}"
      puts "  Next minimum level: #{stats[:next_min]}"
      puts "  Maximum level: #{stats[:max]}"
      0
    end

    desc "projection DICOM-DIR", "extract projected images from a DICOM sequence"
    option :output,   desc: 'output directory', aliases: '-o'
    option :axial,    desc: 'N for single slice, * all, C center, mip or aap for volumetric aggregation'
    option :sagittal, desc: 'N for single slice, * all, C center, mip or aap for volumetric aggregation'
    option :coronal,  desc: 'N for single slice, * all, C center, mip or aap for volumetric aggregation'
    option :transfer,   desc: 'transfer method', aliases: '-t', default: 'identity'
    # option :byte,       desc: 'transfer as bytes', aliases: '-b'
    option :center,     desc: 'center (window transfer)', aliases: '-c'
    option :width,      desc: 'window (window transfer)', aliases: '-w'
    option :ignore_min, desc: 'ignore minimum (global/first/sample transfer)', aliases: '-i'
    option :samples,    desc: 'number of samples (sample transfer)', aliases: '-s'
    def projection(dicom_dir)
      DICOM.logger.level = Logger::FATAL
      settings = {} # TODO: ...
      unless File.directory?(dicom_dir)
        raise Error, set_color("Directory not found: #{dicom_dir}", :red)
        say options
      end
      unless options.axial || options.sagittal || options.coronal
        raise Error, "Must specify at least one projection (axial/sagittal/coronal)"
      end
      packer = DicomPack.new(settings)
      packer.projection(
        dicom_dir,
        transfer: DicomPack.transfer_options(options),
        output: options.output,
        axial: options.axial == 'axial' ? 'mip' : options.axial,
        sagittal: options.sagittal == 'sagittal' ? 'mip' : options.sagittal,
        coronal: options.coronal == 'coronal' ? 'mip' : options.coronal
      )
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
    def remap(dicom_dir)
      DICOM.logger.level = Logger::FATAL
      settings = {} # TODO: ...
      unless File.directory?(dicom_dir)
        raise Error, set_color("Directory not found: #{dicom_dir}", :red)
        say options
      end
      packer = DicomPack.new(settings)
      packer.remap(
        dicom_dir,
        transfer: DicomPack.transfer_options(options),
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
      if params.empty?
        strategy
      else
        [strategy, params]
      end
    end
  end
end
