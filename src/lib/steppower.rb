module Kadeploy

module Macrostep
  class PowerOn < Power
    def steps()
      [
        [ :power, :on, context[:execution].level ],
      ]
    end
  end

  class PowerOff < Power
    def steps()
      [
        [ :power, :off, context[:execution].level ],
      ]
    end
  end

  class PowerStatus < Power
    def steps()
      [
        [ :power, :status, nil ],
      ]
    end
  end
end

end
