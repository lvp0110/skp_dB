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
      small, large = toolbar_icons
      cmd.small_icon = small if small
      cmd.large_icon = large if large
      toolbar.add_item(cmd)
      toolbar.restore
      toolbar.show
      toolbar
    end

    def self.toolbar_icons
      images = File.join(MODULE_PATH, 'images')
      mac = osx?
      small_name = mac ? 'tb_skpdb_32.png' : 'tb_skpdb_24.png'
      large_name = mac ? 'tb_skpdb_64.png' : 'tb_skpdb_32.png'
      small = File.join(images, small_name).tr('\\', '/')
      large = File.join(images, large_name).tr('\\', '/')
      small = nil unless File.exist?(small)
      large = nil unless File.exist?(large)
      [small, large]
    end

    unless file_loaded?(__FILE__)
      UI.menu('Plugins').add_item("#{PLUGIN_NAME}…") { open_window }
      create_toolbar
      ModelIndex.attach!
      file_loaded(__FILE__)
    end

  end
end
