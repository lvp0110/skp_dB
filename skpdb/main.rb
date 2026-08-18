require 'sketchup.rb'

require_relative 'constants'
require_relative 'http_client'
require_relative 'session'
require_relative 'api'
require_relative 'model_index'
require_relative 'transfer'
require_relative 'app_window'

module Constrtodo
  module SkpDb

    def self.open_window
      AppWindow.show
    end

    def self.create_toolbar
      toolbar = UI::Toolbar.new(PLUGIN_NAME)

      cmd = UI::Command.new(PLUGIN_NAME) { open_window }
      cmd.tooltip = PLUGIN_NAME
      cmd.status_bar_text = 'Получить или отправить модель SketchUp через ConstrTodo'
      cmd.menu_text = 'Открыть…'
      toolbar.add_item(cmd)
      toolbar.restore
      toolbar
    end

    unless file_loaded?(__FILE__)
      UI.menu('Plugins').add_item("#{PLUGIN_NAME}…") { open_window }
      create_toolbar
      ModelIndex.attach!
      file_loaded(__FILE__)
    end

  end
end
