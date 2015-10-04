require 'solver'
require 'narray'

class DicomS

  # Compute sigmoid function s(x) = 1 - exp(-((x - x0)**gamma)/k) for x >= x0;
  # with s(x) = 0 for x < x0).
  #
  # 0 <= s(x) < 1 for all x
  #
  # Defined by two parameters:
  #
  # * w width of the sigmoid
  # * xc center of the sigmoid (s(xc) = 1/2)
  #
  # The interpretation of w is established by a constant 0 < k0 << 1
  # where y1 = s(x1) = k0 and y2 = s(x2) = 1 - k0 and
  # x1 = xc - w/2 and x2 = xc + w/2
  #
  # The gamma factor should be fixed a priori, e.g. gamma = 4
  #
  # k0 = 0.01
  # w = 3.0
  # xc = 7.0
  # sigmod = Sigmoid.new(k0, w, xc)
  # 0.5 == sigmoid[xc]
  # k0 == sigmod[xc - w/2]
  # 1 - k0 == sigmod[xc + w/2]
  class Sigmoid

    def initialize(options = {})
      k0 = options[:k0] || 0.05
      w  = options[:width]
      xc = options[:center]
      @gamma = options[:gamma] || 4.0
      tolerance = options[:tolerance] || Flt::Tolerance(0.01, :relative)

      # Compute the parameters x0 and gamma which define the sigmoid
      # given k0, w and xc

      yc = 0.5
      x1 = xc - w/2
      x2 = xc + w/2
      y1 = k0
      y2 = 1 - k0
      @gamma = 4.0

      # We have two equations to solve for x0, gamma:
      # * yc == 1 - Math.exp(-((xc - x0)**gamma)/k)
      # * y1 == 1 - Math.exp(-((x1 - x0)**gamma)/k)
      # Equivalently we could substitute the latter for
      # * y2 == 1 - Math.exp(-((x2 - x0)**gamma)/k)
      #
      # So, we use the first equation to substitute in the second
      # one of these:
      #
      # * x0 = xc - (-k*Math.log(1 - yc))**(1/gamma)
      # * k = - (xc - x0)**gamma / Math.log(1 - yc)
      #
      # * gamma = Math.log(-k*Math.log(1 - yc))/Math.log(xc - x0)
      #
      # So we could solve either this for k:
      #
      # * y1 == 1 - Math.exp(-((x1 - xc + (-k*Math.log(1 - yc))**(1/gamma))**gamma)/k)
      #
      # or this for x0
      #
      # * y1 == 1 - Math.exp(-((x1 - x0)**gamma)/(- (xc - x0)**gamma / Math.log(1 - yc)))
      algorithm = Flt::Solver::RFSecantSolver

      if true
        g = @gamma
        eq = ->(k) {
          y1 - 1 + exp(-((x1 - xc + (-k*log(1 - yc))**(1/g))**g)/k) }
        solver = algorithm.new(Float.context, tolerance, &eq)
        @k = solver.root(1.0, 100.0)
        @x0 = xc - (-@k*Math.log(1 - yc))**(1/@gamma)
      else
        g = @gamma
        eq = ->(x0) { y1 - 1 + exp(-((x1 - x0)**g)/(- (xc - x0)**g / log(1 - yc))) }
        solver = algorithm.new(Float.context, tolerance, &eq)
        @x0 = solver.root(0.0, 100.0)
        @k = - (xc - @x0)**@gamma / Math.log(1 - yc)
      end
    end

    def [](x)
      if x.is_a? NArray
        narray_sigmoid x
      else
        if x <= @x0
          0.0
        else
          1.0 - Math.exp(-((x - @x0)**@gamma)/@k)
        end
      end
    end

    attr_reader :gamma, :k, :x0

    private

    def narray_sigmoid(x)
      x[x <= @x0] = 0
      ne0 = x.ne(0)
      y = x[ne0]
      y.sbt! @x0
      y = power(y, @gamma)
      y.div! -@k
      y = NMath.exp(y)
      y.mul! -1
      y.add! 1
      x[ne0] = y
      x
    end

    def power(x, y)
      NMath.exp(y*NMath.log(x))
    end
  end
end
