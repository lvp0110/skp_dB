require 'json'
require 'fileutils'

module Constrtodo
  module SkpDb

    # На Mac SketchUp держит несколько окон, но API отдаёт только active_model.
    # На Windows каждое окно — отдельный процесс: копим локальные модели и
    # соседние экземпляры через общий файл, чтобы список окон был полным.
    module ModelIndex
      @models = {}
      @attached = false
      @opening = nil
      @selected_id = nil
      @poll_started = false

      module_function

      def attach!
        return if @attached

        Sketchup.add_observer(Observer.new)
        remember(Sketchup.active_model)
        publish!
        @attached = true
        start_poll!
        [0.8, 2.0, 4.0, 8.0, 12.0].each do |delay|
          UI.start_timer(delay, false) { Transfer.consume_pending_open! if defined?(Transfer) }
        end
      end

      def start_poll!
        return if @poll_started

        @poll_started = true
        UI.start_timer(1.0, true) do
          Transfer.consume_pending_open! if defined?(Transfer)
          Transfer.consume_pending_command! if defined?(Transfer)
          if AppWindow.visible?
            sync_foreground_selection!
            publish!
            AppWindow.push_open_models
            AppWindow.reassert_stack!
          end
        end
      end

      def remember(model)
        return if model.nil?

        @models[model.object_id] = model
        prune!
        publish!
      end

      def prune!
        @models.select! { |_id, model| alive?(model) }
      end

      def alive?(model)
        return false if model.nil?

        model.entities
        true
      rescue StandardError
        false
      end

      def all
        prune!
        remember(Sketchup.active_model)
        @models.values
      end

      def find(object_id)
        prune!
        key = object_id.to_s
        return nil if key.start_with?('ext:', 'pending:')

        model = @models[object_id.to_i]
        return model if alive?(model)

        active = Sketchup.active_model
        return active if active && active.object_id == object_id.to_i

        nil
      end

      def remote?(object_id)
        key = object_id.to_s
        key.start_with?('ext:', 'pending:')
      end

      def announce_opening(path, name)
        normalized = normalize_path(path)
        @opening = {
          objectId: "pending:#{normalized.hash.abs}",
          name: name.to_s,
          path: path.to_s,
          active: true,
          modified: false,
          entities: 0,
          local: false,
          pending: true,
          pid: 0
        }
        @opening[:name] = File.basename(path.to_s, '.*') if @opening[:name].empty?
        @selected_id = @opening[:objectId]
        publish!
        UI.start_timer(20, false) do
          if @opening && normalize_path(@opening[:path]) == normalized
            @opening = nil
            AppWindow.push_open_models if AppWindow.visible?
          end
        end
      end

      def summaries
        active = Sketchup.active_model
        items = all.map { |model| summary(model, active) }
        merge_external!(items)
        apply_opening!(items)
        apply_selection!(items)
        items.sort_by { |item| item[:active] ? 0 : 1 }
      end

      def activate(object_id)
        key = object_id.to_s
        return false if key.empty?

        @selected_id = key
        model = find(key)
        if model
          activate_os_window(Process.pid, display_name(model))
        else
          pid = pid_for(key)
          activate_os_window(pid, name_for(key))
        end
        true
      rescue StandardError => e
        puts "[SkpDb] activate: #{e.message}"
        false
      end

      def pid_for(object_id)
        key = object_id.to_s
        return key.split(':')[1].to_i if key.start_with?('ext:')

        Process.pid
      end

      def name_for(object_id)
        key = object_id.to_s
        item = summaries.find { |entry| entry[:objectId].to_s == key }
        return item[:name] if item

        model = find(key)
        model ? display_name(model) : ''
      end

      def summary(model, active = nil)
        active ||= Sketchup.active_model
        payload = {
          objectId: model.object_id,
          name: display_name(model),
          path: display_path(model),
          active: !!(active && model.object_id == active.object_id),
          modified: model.respond_to?(:modified?) ? !!model.modified? : false,
          entities: model.entities.count,
          local: true,
          pid: Process.pid
        }
        merge_catalog_fields!(payload, model.path.to_s)
        payload
      rescue StandardError => e
        {
          objectId: model.object_id,
          name: "Модель #{model.object_id}",
          path: '',
          active: false,
          modified: false,
          entities: 0,
          local: true,
          pid: Process.pid,
          error: e.message
        }
      end

      def display_name(model)
        human_name(model.title.to_s, model.path.to_s, model.entities.count)
      end

      def display_path(model)
        path = model.path.to_s.strip
        return '' if path.empty? || temp_path?(path)

        path
      end

      def human_name(title, path = '', entity_count = 0)
        file_base = path.to_s.strip.empty? ? '' : File.basename(path, '.*')
        title_base = basename_if_path(title)
        name = placeholder_title?(title_base) ? file_base : title_base
        name = file_base if name.empty?
        name = "Без имени (#{entity_count} объектов)" if name.empty?
        name
      end

      def basename_if_path(text)
        value = text.to_s.strip
        return value if value.empty?
        return File.basename(value.tr('\\', '/'), '.*') if value.include?('/') || value.include?('\\')

        value
      end

      def temp_path?(path)
        text = path.to_s
        return true if text.empty?
        return true if text.include?('constrtodo_skpdb')
        return true if text.include?('/var/folders/')
        return true if text.include?('\\Temp\\') || text.include?('/Temp/')

        temp = Sketchup.temp_dir.to_s
        !temp.empty? && text.start_with?(temp)
      rescue StandardError
        false
      end

      def bind_catalog(info)
        info = stringify_bind(info)
        path = normalize_path(info['path'])
        return if path.empty?

        all = read_bindings
        all[path] = info.merge('path' => File.expand_path(info['path'].to_s), 'updatedAt' => Time.now.to_i)
        write_bindings(all)
      end

      def window_for_content(content_id)
        id = content_id.to_s
        return nil if id.empty?

        summaries.find { |item| item[:catalogContentId].to_s == id }
      end

      def catalog_binding_for_path(path)
        key = normalize_path(path)
        return nil if key.empty?

        bind = read_bindings[key]
        bind.is_a?(Hash) ? bind : nil
      end

      def merge_catalog_fields!(item, path)
        bind = catalog_binding_for_path(path) || catalog_binding_for_path(item[:path])
        return item unless bind

        item[:catalogContentId] = bind['contentId']
        item[:catalogGroupId] = bind['groupId']
        item[:catalogStatus] = bind['status']
        item[:catalogMode] = bind['mode']
        item[:catalogLabels] = Array(bind['labels'])
        item
      end
      private_class_method :merge_catalog_fields!

      def update_catalog_binding(content_id, attrs)
        id = content_id.to_s
        return if id.empty?

        all = read_bindings
        changed = false
        all.each do |path, info|
          next unless info.is_a?(Hash) && info['contentId'].to_s == id

          all[path] = stringify_bind(info).merge(stringify_bind(attrs))
          all[path]['updatedAt'] = Time.now.to_i
          changed = true
        end
        write_bindings(all) if changed
      end

      def stringify_bind(obj)
        return {} unless obj.is_a?(Hash)

        obj.each_with_object({}) do |(key, value), acc|
          acc[key.to_s] = value
        end
      end
      private_class_method :stringify_bind

      def bindings_path
        File.join(Session.user_data_dir, 'catalog_bindings.json')
      end
      private_class_method :bindings_path

      def read_bindings
        path = bindings_path
        return {} unless File.exist?(path)

        parsed = JSON.parse(File.read(path).to_s)
        parsed.is_a?(Hash) ? parsed : {}
      rescue StandardError
        {}
      end
      private_class_method :read_bindings

      def write_bindings(hash)
        FileUtils.mkdir_p(File.dirname(bindings_path))
        File.open(bindings_path, 'w') { |file| file.write(JSON.generate(hash)) }
      rescue StandardError
        nil
      end
      private_class_method :write_bindings

      def placeholder_title?(name)
        %w[untitled untitled.skp sketchup model без имени новая модель].include?(name.to_s.strip.downcase)
      end

      def unregister!
        @opening = nil
        write_registry(read_registry.reject { |entry| entry['pid'].to_i == Process.pid })
      rescue StandardError
        nil
      end

      def merge_external!(items)
        local_paths = items.map { |item| normalize_path(item[:path]) }.reject(&:empty?)
        read_registry.each do |entry|
          pid = entry['pid'].to_i
          next if pid == Process.pid
          next unless pid_alive?(pid)

          path = entry['path'].to_s
          next if !path.empty? && local_paths.include?(normalize_path(path))

          items << {
            objectId: "ext:#{pid}:#{entry['objectId']}",
            name: entry['name'].to_s,
            path: path,
            active: false,
            modified: !!entry['modified'],
            entities: entry['entities'].to_i,
            local: false,
            pid: pid
          }
          merge_catalog_fields!(items.last, path)
        end
      rescue StandardError
        nil
      end
      private_class_method :merge_external!

      def apply_opening!(items)
        return unless @opening.is_a?(Hash)

        wanted = normalize_path(@opening[:path])
        match = items.find { |item| !item[:path].to_s.empty? && normalize_path(item[:path]) == wanted }
        if match
          items.each { |item| item[:active] = false }
          match[:active] = true
          @opening = nil unless match[:pending]
        else
          items.each { |item| item[:active] = false }
          items << @opening.merge(active: true, local: false)
        end
      end
      private_class_method :apply_opening!

      def apply_selection!(items)
        wanted = @selected_id.to_s
        return if wanted.empty?

        if items.any? { |item| item[:objectId].to_s == wanted }
          items.each { |item| item[:active] = item[:objectId].to_s == wanted }
        end
      end
      private_class_method :apply_selection!

      def sync_foreground_selection!
        fg_hwnd = AppWindow.foreground_hwnd.to_i
        return if fg_hwnd <= 0
        return if AppWindow.plugin_hwnd?(fg_hwnd)

        fg = foreground_pid
        return if fg.nil? || fg <= 0

        if fg == Process.pid
          model = @models.values.find { |item| alive?(item) }
          @selected_id = model.object_id.to_s if model
          unless AppWindow.stacked_pid == Process.pid
            AppWindow.raise_model_window!(Process.pid, other_pids: known_pids, activate: false)
          end
          return
        end

        return unless known_pid?(fg)

        entry = read_registry.find { |item| item['pid'].to_i == fg }
        return unless entry

        @selected_id = "ext:#{fg}:#{entry['objectId']}"
        return if AppWindow.stacked_pid == fg

        AppWindow.raise_model_window!(fg, other_pids: known_pids, activate: false)
      rescue StandardError
        nil
      end

      def known_pid?(pid)
        return true if pid.to_i == Process.pid

        read_registry.any? { |item| item['pid'].to_i == pid.to_i }
      end
      private_class_method :known_pid?

      def known_pids
        pids = [Process.pid]
        read_registry.each { |entry| pids << entry['pid'].to_i }
        pids.select { |pid| pid > 0 }.uniq
      end
      private_class_method :known_pids

      def activate_os_window(pid, name)
        if ::Constrtodo::SkpDb.osx?
          activate_mac_window(name)
          AppWindow.keep_on_top! if AppWindow.visible?
        else
          AppWindow.raise_model_window!(pid, other_pids: known_pids, activate: true)
        end
      end
      private_class_method :activate_os_window

      def activate_win_pid(pid, name = nil)
        pid = pid.to_i
        return if pid <= 0

        require 'win32ole'
        shell = WIN32OLE.new('WScript.Shell')
        return if shell.AppActivate(pid)

        title = name.to_s
        shell.AppActivate(title) unless title.empty?
      rescue StandardError => e
        puts "[SkpDb] AppActivate: #{e.message}"
        nil
      end
      private_class_method :activate_win_pid

      def activate_mac_window(name)
        needle = name.to_s.gsub(/["\\]/, '')
        script = %(
          tell application "SketchUp" to activate
          tell application "System Events"
            if exists process "SketchUp" then
              tell process "SketchUp"
                set frontmost to true
                if "#{needle}" is not "" then
                  try
                    perform action "AXRaise" of (first window whose name contains "#{needle}")
                  end try
                end if
              end tell
            end if
          end tell
        )
        IO.popen(['osascript', '-e', script], 'r') { |io| io.read }
      rescue StandardError
        nil
      end
      private_class_method :activate_mac_window

      def foreground_pid
        return nil if ::Constrtodo::SkpDb.osx?

        require 'fiddle'
        user32 = Fiddle.dlopen('user32.dll')
        get_fore = Fiddle::Function.new(user32['GetForegroundWindow'], [], Fiddle::TYPE_VOIDP)
        get_tid = Fiddle::Function.new(
          user32['GetWindowThreadProcessId'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
          Fiddle::TYPE_INT
        )
        hwnd = get_fore.call
        return nil if hwnd.nil? || hwnd.to_i == 0

        buf = Fiddle::Pointer.malloc(8)
        buf[0, 8] = 0.chr * 8
        get_tid.call(hwnd, buf)
        buf[0, 4].unpack('L').first.to_i
      rescue StandardError
        nil
      end
      private_class_method :foreground_pid

      def publish!
        prune!
        active = Sketchup.active_model
        ours = @models.values.select { |model| alive?(model) }.map do |model|
          {
            'pid' => Process.pid,
            'objectId' => model.object_id,
            'name' => display_name(model),
            'path' => model.path.to_s,
            'modified' => model.respond_to?(:modified?) ? !!model.modified? : false,
            'entities' => begin
                            model.entities.count
                          rescue StandardError
                            0
                          end,
            'active' => !!(active && model.object_id == active.object_id),
            'updatedAt' => Time.now.to_i
          }
        end
        others = read_registry.reject { |entry| entry['pid'].to_i == Process.pid || !pid_alive?(entry['pid'].to_i) }
        write_registry(others + ours)
      rescue StandardError
        nil
      end
      private_class_method :publish!

      def read_registry
        path = registry_path
        return [] unless File.exist?(path)

        parsed = JSON.parse(File.read(path).to_s)
        parsed.is_a?(Array) ? parsed.select { |item| item.is_a?(Hash) } : []
      rescue StandardError
        []
      end
      private_class_method :read_registry

      def write_registry(entries)
        dir = File.dirname(registry_path)
        FileUtils.mkdir_p(dir)
        File.open(registry_path, 'w') { |file| file.write(JSON.generate(entries)) }
      rescue StandardError
        nil
      end
      private_class_method :write_registry

      def registry_path
        File.join(Session.user_data_dir, 'open_windows.json')
      end
      private_class_method :registry_path

      def pid_alive?(pid)
        pid = pid.to_i
        return false if pid <= 0

        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      rescue StandardError
        true
      end
      private_class_method :pid_alive?

      def normalize_path(path)
        File.expand_path(path.to_s).downcase.tr('\\', '/')
      rescue StandardError
        path.to_s.downcase.tr('\\', '/')
      end
      private_class_method :normalize_path

      class Observer < Sketchup::AppObserver
        def expectsStartupModelNotifications
          true
        end

        def onNewModel(model)
          ModelIndex.prune!
          ModelIndex.remember(model)
          UI.start_timer(1.2, false) { Transfer.consume_pending_open! if defined?(Transfer) }
          AppWindow.push_open_models
        end

        def onOpenModel(model)
          ModelIndex.prune!
          ModelIndex.remember(model)
          AppWindow.push_open_models
        end

        def onActivateModel(model)
          ModelIndex.remember(model)
          AppWindow.push_open_models
        end

        def onQuit
          ModelIndex.unregister!
        end
      end
    end

  end
end
