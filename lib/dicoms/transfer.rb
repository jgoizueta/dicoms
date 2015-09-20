class DicomS
  # Base class for Transfer strategy classes that define how
  # the values of DICOM pixels are scales to be used as image pixels
  # or to be processed as data (generic presentation values).
  #
  # Different strategies determine how much of the original
  # data dynamic range is preserved.
  #
  # All the Transfer-derived classes can pass an :output option to the base
  # which changes output range limits from what is stored in the DICOM.
  # Two values are supported:
  #
  # * :byte Output consist of single byte values (0-255)
  # * :unsigned Output is always unsigned
  #
  # The method min_max(sequence) of each class returns the minimum and maximum
  # values which are mapped to the output limits.
  # These values may be raw or rescaled depending on the min_max_rescaled? method
  #
  # Derived classes should also provide a method
  #
  #     transfer_rescaled_pixels(dicom, data, min, max)
  #
  # To apply the transfer conversion to data which has been only rescaled
  #
  class Transfer
    USE_DATA = false

    include Support
    extend  Support

    def initialize(options = {})
      @output = options[:output]
    end

    # Remapped DICOM pixel values as an Image
    def image(dicom, min, max)
      assign_dicom_pixels dicom, pixels(dicom, min, max)
      dicom.image
    end

    # Remapped DICOM pixel values as an NArray
    def pixels(dicom, min, max)
      processed_data(dicom, min, max)
    end

    def self.strategy(strategy, options = {})
      if strategy.is_a?(Array) && options.empty?
        strategy, options = strategy
      end
      return nil if strategy.nil?
      case strategy.to_sym
      when :fixed
        strategy_class = FixedTransfer
      when :window
        strategy_class = WindowTransfer
      when :first
        strategy_class = FirstTransfer
      when :global
        strategy_class = GlobalTransfer
      when :sample
        strategy_class = SampleTransfer
      when :identity
        strategy_class = IdentityTransfer
      else
        raise "INVALID: #{strategy.inspect}"
      end
      strategy_class.new options
    end

    # absolute output limits of the range (raw, not rescaled)
    def min_max_limits(dicom)
      case @output
      when :byte
        [0, 255]
      when :unsigned
        min, max = Transfer.min_max_limits(dicom)
        if min < 0
          max -= min
          min = 0
        end
        [min, max]
      else
        Transfer.min_max_limits(dicom)
      end
    end

    def self.min_max_limits(dicom)
      num_bits = dicom_bit_depth(dicom)
      signed = dicom_signed?(dicom)
      pixel_value_range(num_bits, signed)
    end

    FLOAT_MAPPING = true

  end

  # Apply window-clipping; also
  # always apply rescale (remap)
  class WindowTransfer < Transfer

    def initialize(options = {})
      @center = options[:center]
      @width  = options[:width]
      @float_arith = options[:float] || FLOAT_MAPPING
      super options
    end

    def min_max(sequence)
      # TODO: use options to sample/take first/take all?
      dicom = sequence.first
      data_range dicom
    end

    def min_max_rescaled?
      true
    end

    def processed_data(dicom, min, max)
      center = (min + max)/2
      width = max - min
      data = dicom_narray(dicom, level: [center, width])
      map_to_output dicom, data, min, max
    end

    # Apply the transfer map to data which has been only rescaled
    def transfer_rescaled_pixels(dicom, pixels, min, max)
      # clip pixels to min, max # wouldn't be needed if map_to_output did output clipping...
      pixels[pixels < min] = min
      pixels[pixels > max] = max
      map_to_output dicom, pixels, min, max
    end

    # def image(dicom, min, max)
    #   center = (min + max)/2
    #   width = max - min
    #   dicom.image(level: [center, width]).normalize
    # end

    private

    def map_to_output(dicom, data, min, max)
      output_min, output_max = min_max_limits(dicom)
      output_range = output_max - output_min
      input_range  = max - min
      float_arith = @float_arith || output_range < input_range
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
        data = dicom_narray(dicom, level: level)
        [data.min, data.max]
      else
        center = @center || dicom_window_center(dicom)
        width  = @width  || dicom_window_width(dicom)
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
  #
  # +:ignore_min+ is used to ignore the minimum level present in the data
  # and look for the next minimum value. Usually the absolute minimum
  # corresponds to parts of the image outside the registered area and has
  # typically the value -2048 for CT images. The next minimum value
  # usually corresponds to air and is what's taken as the image's minimum
  # when this option is set to +true+.
  #
  class RangeTransfer < Transfer

    def initialize(options = {})
      options = { ignore_min: true }.merge(options)
      @rescale = options[:rescale]
      @ignore_min = options[:ignore_min]
      @extension_factor = options[:extend] || 0.0
      @float_arith = options[:float] || FLOAT_MAPPING
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

    # Apply the transfer map to data which has been only rescaled
    def transfer_rescaled_pixels(dicom, data, min, max)
      output_min, output_max = min_max_limits(dicom)
      output_range = output_max - output_min
      input_range  = max - min
      float_arith = @float_arith || output_range < input_range
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

    def processed_data(dicom, min, max)
      data = dicom_narray(dicom, level: false, remap: @rescale)
      transfer_rescaled_pixels dicom, data, min, max
    end

    def min_max_rescaled?
      @rescale
    end

    private

    def data_range(dicom)
      data = dicom_narray(dicom, level: false, remap: @rescale)
      base = nil
      minimum = data.min
      maximum = data.max
      if @ignore_min
        base = minimum
        minimum  = (data[data > base].min)
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

  class FixedTransfer < RangeTransfer

    def initialize(options = {})
      @fixed_min = options[:min] || -2048
      @fixed_max = options[:max] || +2048
      options[:ignore_min] = false
      options[:extend] = nil
      unless options.key?(:rescale)
        options[:rescale] = true
      end
      super options
    end

    def min_max(sequence)
      # TODO: set default min, max regarding dicom data type
      [@fixed_min, @fixed_max]
    end

  end

  class GlobalTransfer < RangeTransfer

    private

    def select_dicoms(sequence, &blk)
      sequence.each &blk
    end

  end

  class FirstTransfer < RangeTransfer

    def initialize(options = {})
      extend = options[:extend] || 0.3
      super options.merge(extend: extend)
    end

    private

    def select_dicoms(sequence, &blk)
      blk[sequence.first] if sequence.size > 0
    end

  end

  class SampleTransfer < RangeTransfer

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

  # Preserve internal values.
  # Can be used with the output: :unsinged option
  # to convert signed values to unsinged.
  class IdentityTransfer < FixedTransfer
    def initialize(options = {})
      super options
    end

    def min_max(sequence)
      Transfer.min_max_limits(sequence.first)
    end
  end
end
