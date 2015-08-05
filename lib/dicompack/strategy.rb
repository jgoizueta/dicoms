class DicomPack

  # Classes derived from ... are used to map
  # DICOM pixel values to output levels (gemeric presetation values).
  # Each class defines a dynamic-rage strategy that
  # Maps pixel values/presentation values to output levels.
  # A Dynamic-range strategy determines how are data values
  # mapped to pixel intensities in DICOM images
  class DynamicRangeStrategy  # PixelValueMapper RageMapper Transfer
    # TODO: rename this class to RangeMapper or DataMapper ...

    def initialize(options = {})
      @force_8_bit_processing = (options[:bits] == 8)
    end

    # Remapped DICOM pixel values as an Image
    def image(dicom, min, max)
      dicom.pixels = pixels(dicom, min, max)
      dicom.image
    end

    # Remapped DICOM pixel values as an NArray
    def pixels(dicom, min, max)
      processed_data(dicom, min, max)
    end

    def self.min_max_strategy(strategy, options = {})
      case strategy
      when :fixed
        strategy_class = FixedStrategy
      when :window
        strategy_class = WindowStrategy
      when :first
        strategy_class = FirstStrategy
      when :global
        strategy_class = GlobalStrategy
      when :sample
        strategy_class = SampleStrategy
      end
      strategy_class.new options
    end

    def min_max_limits(dicom)
      if @force_8_bit_processing
        [0, 255]
      else
        DynamicRangeStrategy.min_max_limits(dicom)
      end
    end

    def self.min_max_limits(dicom)
      signed = dicom.send(:signed_pixels?)
      if dicom.bits_stored.value.to_i == 16
        if signed
          [-32768, 32767]
        else
          [0, 65535]
        end
      elsif signed
        [-128, 127]
      else
        [0, 255]
      end
    end

    FLOAT_MAPPING = true

  end

  # Apply window-clipping; also
  # always apply rescale (remap)
  class WindowStrategy < DynamicRangeStrategy

    def initialize(options = {})
      @center = options[:center]
      @width  = options[:width]
      super options
    end

    def min_max(sequence)
      # TODO: use options to sample/take first/take all?
      dicom = sequence.first
      data_range dicom
    end

    def processed_data(dicom, min, max)
      center = (min + max)/2
      width = max - min
      data = dicom.narray(level: [center, width])
      map_to_output dicom, data, min, max
    end

    # def image(dicom, min, max)
    #   center = (min + max)/2
    #   width = max - min
    #   dicom.image(level: [center, width]).normalize
    # end

    private

    USE_DATA = false

    def map_to_output(dicom, data, min, max)
      output_min, output_max = min_max_limits(dicom)
      output_range = output_max - output_min
      input_range  = max - min
      float_arith = FLOAT_MAPPING || output_range < input_range
      data_type = data.typecode
      data = data.to_type(NArray::SFLOAT) if float_arith
      data.sbt! min
      data.mul! (output_range).to_f/(input_range)
      data.add! output_min
      data = data.to_type(data_type) if float_arith
      data
    end

    def data_range(dicom)
      if USE_DATA
        if @center && @width
          level = [@center, @width]
        else
          level = true
        end
        data = dicom.narray(level: level)
        [data.min, data.max]
      else
        center = @center || dicom.window_center.value.to_i
        width  = @width  || dicom.window_width.value.to_i
        low = center - width/2
        high = center + width/2
        [low, high]
      end
    end

  end

  # These strategies
  # have optional dropping of the lowest level (base),
  # photometric rescaling, extension factor
  # and map the minimum/maximum input values
  # (determined by the particular strategy and files)
  # to the minimum/maximum output levels (black/white)
  class RangeStrategy < DynamicRangeStrategy

    def initialize(options = {})
      @rescale = options[:rescale]
      @drop_base = options[:drop_base]
      @extension_factor = options[:extend] || 0.0
      super options
    end

    def min_max(sequence)
      v0 = minimum = maximum = nil
      select_dicoms(sequence) do |d|
        d_v0, d_min, d_max = data_range(d)
        v0 ||= d_v0
        minimum ||= d_min
        maximum ||= d_max
        v0 = d_v0 if v0 && d_v0 && v0 > d_v0
        minimum = d_min if minimum > d_min
        maximum = d_max if maximum < d_max
      end
      [minimum, maximum]
    end

    def processed_data(dicom, min, max)
      output_min, output_max = min_max_limits(dicom)
      output_range = output_max - output_min
      input_range  = max - min
      float_arith = FLOAT_MAPPING || output_range < input_range
      data = dicom.narray(level: false, remap: @rescale)
      data_type = data.typecode
      data = data.to_type(NArray::SFLOAT) if float_arith
      data.sbt! min
      data.mul! output_range/input_range.to_f
      data.add! output_min
      data[data < output_min] = output_min
      data[data > output_max] = output_max
      data = data.to_type(data_type) if float_arith
      data
    end

    private

    def data_range(dicom)
      data = dicom.narray(level: false, remap: @rescale)
      base = nil
      minimum = data.min
      maximum = data.max
      if @drop_base
        base = minimum
        minumum  = data[data > base].min
      end
      if @extension_factor != 0
        # extend the range
        minimum, maximum = extend_data_range(@extension_factor, base, minimum, maximum)
      end
      [base, minimum, maximum]
    end

    def extend_data_range(k, base, minimum, maximum)
      k += 1.0
      c = (maximum + minimum)/2
      minimum = (c + k*(minimum - c)).round
      maximum = (c + k*(maximum - c)).round
      if base
        minimum = base + 1 if minimum <= base
      end
      [minimum, maximum]
    end

  end


  class FixedStrategy < RangeStrategy

    def initialize(options = {})
      @fixed_min = options[:min] || -2048
      @fixed_max = options[:max] || +2048
      options[:drop_base] = false
      options[:extend] = nil
      super options
    end

    def min_max(sequence)
      # TODO: set default min, max regarding dicom data type
      [@fixed_min, @fixed_max]
    end

  end

  class GlobalStrategy < RangeStrategy

    private

    def select_dicoms(sequence, &blk)
      sequence.each &blk
    end

  end

  class FirstStrategy < RangeStrategy

    def initialize(options = {})
      extend = options[:extend] || 0.3
      super options.merge(extend: extend)
    end

    private

    def select_dicoms(sequence, &blk)
      blk[sequence.first] if sequence.size > 0
    end

  end

  class SampleStrategy < RangeStrategy

    def initialize(options = {})
      @max_files = options[:max_files] || 8
      super options
    end

    private

    def select_dicoms(sequence, &blk)
      n = [sequence.size, @max_files].min
      (0...sequence.size).to_a.sample(n).sort.each do |i|
        blk[sequence.dicom(i)]
      end
    end

  end
end
