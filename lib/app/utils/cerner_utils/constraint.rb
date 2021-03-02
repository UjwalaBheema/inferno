module Inferno
  class Constraint
    attr_accessor :type, :parameters, :name, :groups

    def initialize(opts)
      @type = opts['type']
      @parameters = opts['parameters']
      @name = opts['name']
      @groups = opts['groups']
    end
  end
end

