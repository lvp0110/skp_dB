require 'sketchup.rb'
require 'extensions.rb'

module Constrtodo
  module SkpDb

    unless file_loaded?(__FILE__)
      ex = SketchupExtension.new('ConstrTodo SKP', 'skpdb/main')
      ex.description = 'Получение и отправка моделей SketchUp через ConstrTodo.'
      ex.version     = '1.1.1'
      ex.copyright   = 'ConstrTodo'
      ex.creator     = 'SKP dB'
      Sketchup.register_extension(ex, true)
      file_loaded(__FILE__)
    end

  end
end
