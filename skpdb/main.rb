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
      AppWindow.show_shared
    end

    def self.create_toolbar
      toolbar = UI::Toolbar.new(PLUGIN_NAME)

      cmd = UI::Command.new(PLUGIN_NAME) { open_window }
      cmd.tooltip = PLUGIN_NAME
      cmd.status_bar_text = 'Получить или отправить модель SketchUp через ConstrTodo'
      cmd.menu_text = 'Открыть…'
      apply_command_icons!(cmd)
      toolbar.add_item(cmd)
      toolbar.restore
      toolbar.show
      toolbar
    end

    def self.apply_command_icons!(cmd)
      icon = icon_file('skpdb_icon.png')
      win_png = icon_file('toolbar_win.png')
      small_png = icon_file('toolbar_24.png')
      large_png = icon_file('toolbar_32.png')

      chosen = if File.exist?(icon)
                 icon
               elsif !osx? && File.exist?(win_png)
                 win_png
               elsif File.exist?(large_png)
                 large_png
               elsif File.exist?(small_png)
                 small_png
               end
      return unless chosen

      cmd.small_icon = chosen
      cmd.large_icon = chosen
    rescue StandardError
      nil
    end
    private_class_method :apply_command_icons!

    def self.icon_file(name)
      File.join(ICONS_PATH, name).tr('\\', '/')
    end
    private_class_method :icon_file

    unless file_loaded?(__FILE__)
      UI.menu('Plugins').add_item("#{PLUGIN_NAME}…") { open_window }
      create_toolbar
      ModelIndex.attach!
      file_loaded(__FILE__)
    end

  end
end
