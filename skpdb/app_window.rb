require 'json'
require 'fileutils'

module Constrtodo
  module SkpDb

    module AppWindow
      TITLE = PLUGIN_NAME
      PREF_KEY = 'constrtodo_skpdb_window'.freeze

      @dialog = nil
      @dialog_hwnd = nil
      @stacked_hwnd = nil
      @stacked_pid = nil
      @html_mtime = nil

      module_function

      def show_shared
        host = host_pid
        if host && host != Process.pid && host_alive?(host)
          Transfer.request_command(host, 'show') if defined?(Transfer)
          return
        end

        show
      end

      def show
        claim_host!
        if @dialog
          reload_html_if_changed!
          @dialog.show unless @dialog.visible?
          @dialog.bring_to_front
          schedule_on_top!
          raise_model_window!(Process.pid, activate: false)
          push_open_models
          return
        end

        # Windows: STYLE_WINDOW, чтобы окно не пряталось при фокусе другого процесса SketchUp.
        # Mac: STYLE_DIALOG держит плагин над окнами модели в одном процессе.
        style = if ::Constrtodo::SkpDb.osx? && defined?(UI::HtmlDialog::STYLE_DIALOG)
                  UI::HtmlDialog::STYLE_DIALOG
                elsif defined?(UI::HtmlDialog::STYLE_WINDOW)
                  UI::HtmlDialog::STYLE_WINDOW
                else
                  UI::HtmlDialog::STYLE_DIALOG
                end

        @dialog = UI::HtmlDialog.new(
          dialog_title: TITLE,
          preferences_key: PREF_KEY,
          scrollable: true,
          resizable: true,
          width: 520,
          height: 740,
          min_width: 420,
          min_height: 520,
          style: style
        )

        load_html!(@dialog)
        register_callbacks(@dialog)
        @dialog.set_on_closed do
          unstack_current_model!
          @dialog = nil
          @dialog_hwnd = nil
          @stacked_hwnd = nil
          @stacked_pid = nil
          @html_mtime = nil
          release_host!
        end
        @dialog.show
        schedule_on_top!
        schedule_model_name!
        UI.start_timer(0.35, false) { raise_model_window!(Process.pid, activate: false) if visible? }
      end

      SWP_NOSIZE = 0x0001
      SWP_NOMOVE = 0x0002
      SWP_NOACTIVATE = 0x0010
      SWP_SHOWWINDOW = 0x0040
      HWND_TOPMOST = -1
      HWND_NOTOPMOST = -2
      SW_RESTORE = 9
      GW_CHILD = 5
      GW_HWNDNEXT = 2

      def native_hwnd
        return nil if ::Constrtodo::SkpDb.osx?

        dialog_hwnd
      end
      module_function :native_hwnd

      def plugin_hwnd?(hwnd)
        plugin = native_hwnd.to_i
        plugin > 0 && hwnd.to_i == plugin
      end
      module_function :plugin_hwnd?

      def stacked_pid
        @stacked_pid
      end
      module_function :stacked_pid

      def foreground_hwnd
        require 'fiddle'
        user32 = Fiddle.dlopen('user32.dll')
        fn = Fiddle::Function.new(user32['GetForegroundWindow'], [], Fiddle::TYPE_VOIDP)
        hwnd = fn.call
        hwnd.to_i
      rescue StandardError
        0
      end
      module_function :foreground_hwnd

      def keep_on_top!
        return unless visible?

        if ::Constrtodo::SkpDb.osx?
          @dialog.bring_to_front
          return
        end

        hwnd = dialog_hwnd
        return if hwnd.nil? || hwnd == 0

        set_window_pos!(hwnd, HWND_TOPMOST, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE)
      rescue StandardError => e
        puts "[SkpDb] keep_on_top: #{e.message}"
        nil
      end
      module_function :keep_on_top!

      def raise_model_window!(pid, other_pids: [], activate: true)
        return if ::Constrtodo::SkpDb.osx?
        return unless visible?

        pid = pid.to_i
        return if pid <= 0

        hwnds = model_hwnds_by_pid
        hwnd = hwnds[pid].to_i
        hwnd = fallback_hwnd_for_pid(pid).to_i if hwnd <= 0
        hwnd = @stacked_hwnd.to_i if hwnd <= 0 && @stacked_pid == pid
        return if hwnd <= 0

        restore_window!(hwnd)

        (Array(other_pids).map(&:to_i) + hwnds.keys).uniq.each do |other|
          next if other == pid || other <= 0
          other_hwnd = hwnds[other].to_i
          next if other_hwnd <= 0 || other_hwnd == hwnd

          set_window_pos!(other_hwnd, HWND_NOTOPMOST, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE)
        end
        if @stacked_hwnd && @stacked_hwnd != hwnd && window_alive?(@stacked_hwnd)
          set_window_pos!(@stacked_hwnd, HWND_NOTOPMOST, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE)
        end

        activate_os_title(window_title(hwnd)) if activate
        keep_on_top!
        insert_below_plugin!(hwnd, activate: activate)
        @stacked_hwnd = hwnd
        @stacked_pid = pid

        return unless activate

        [0.05, 0.2, 0.6, 1.2].each do |delay|
          UI.start_timer(delay, false) { reassert_stack! if visible? }
        end
      rescue StandardError => e
        puts "[SkpDb] raise_model_window: #{e.message}"
        nil
      end
      module_function :raise_model_window!

      def reassert_stack!
        keep_on_top!
        return if ::Constrtodo::SkpDb.osx?

        hwnd = @stacked_hwnd.to_i
        if hwnd <= 0 || !window_alive?(hwnd)
          if @stacked_pid.to_i > 0
            hwnd = model_hwnds_by_pid[@stacked_pid].to_i
            hwnd = fallback_hwnd_for_pid(@stacked_pid).to_i if hwnd <= 0
          end
          @stacked_hwnd = hwnd if hwnd > 0
        end
        return if hwnd <= 0

        insert_below_plugin!(hwnd, activate: false)
      rescue StandardError
        nil
      end
      module_function :reassert_stack!

      def schedule_on_top!
        reassert_stack!
        [0.15, 0.5, 1.2, 2.5].each do |delay|
          UI.start_timer(delay, false) { reassert_stack! if visible? }
        end
      end
      private_class_method :schedule_on_top!

      def insert_below_plugin!(hwnd, activate: false)
        plugin = native_hwnd.to_i
        flags = SWP_NOSIZE | SWP_NOMOVE | SWP_SHOWWINDOW
        flags |= SWP_NOACTIVATE unless activate
        if plugin > 0 && plugin != hwnd.to_i
          set_window_pos!(hwnd, plugin, flags)
        else
          set_window_pos!(hwnd, HWND_TOPMOST, flags)
        end
      end
      private_class_method :insert_below_plugin!

      def unstack_current_model!
        return unless @stacked_hwnd && window_alive?(@stacked_hwnd)

        set_window_pos!(@stacked_hwnd, HWND_NOTOPMOST, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE)
      rescue StandardError
        nil
      end
      private_class_method :unstack_current_model!

      def set_window_pos!(hwnd, after, flags)
        require 'fiddle'
        user32 = Fiddle.dlopen('user32.dll')
        fn = Fiddle::Function.new(
          user32['SetWindowPos'],
          [
            Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
            Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT,
            Fiddle::TYPE_INT
          ],
          Fiddle::TYPE_INT
        )
        fn.call(Fiddle::Pointer.new(hwnd.to_i), Fiddle::Pointer.new(after.to_i), 0, 0, 0, 0, flags)
      end
      private_class_method :set_window_pos!

      def restore_window!(hwnd)
        return unless window_iconic?(hwnd)

        require 'fiddle'
        user32 = Fiddle.dlopen('user32.dll')
        fn = Fiddle::Function.new(user32['ShowWindow'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
        fn.call(Fiddle::Pointer.new(hwnd.to_i), SW_RESTORE)
      rescue StandardError
        nil
      end
      private_class_method :restore_window!

      def activate_os_title(title)
        text = title.to_s.strip
        return if text.empty?

        require 'win32ole'
        WIN32OLE.new('WScript.Shell').AppActivate(text)
      rescue StandardError
        nil
      end
      private_class_method :activate_os_title

      def model_hwnds_by_pid
        plugin = native_hwnd.to_i
        best = {}
        areas = {}
        each_top_level_hwnd do |hwnd|
          next if hwnd == plugin
          next unless window_visible?(hwnd) || window_iconic?(hwnd)
          next if dialog_title?(window_title(hwnd))
          next if window_class(hwnd).to_s.include?('Chrome_WidgetWin')

          pid = window_pid(hwnd)
          next if pid <= 0

          area = window_area(hwnd)
          area = 1 if area <= 0 && window_iconic?(hwnd)
          next if area <= 0
          next if areas[pid] && areas[pid] >= area

          best[pid] = hwnd
          areas[pid] = area
        end
        best
      end
      private_class_method :model_hwnds_by_pid

      def fallback_hwnd_for_pid(pid)
        plugin = native_hwnd.to_i
        best = 0
        best_area = -1
        each_top_level_hwnd do |hwnd|
          next if hwnd == plugin
          next if window_pid(hwnd) != pid
          next unless window_visible?(hwnd) || window_iconic?(hwnd)
          next if dialog_title?(window_title(hwnd))

          area = window_area(hwnd)
          area = 1 if area <= 0 && window_iconic?(hwnd)
          next if area <= best_area

          best = hwnd
          best_area = area
        end
        best
      end
      private_class_method :fallback_hwnd_for_pid

      def each_top_level_hwnd
        require 'fiddle'
        user32 = Fiddle.dlopen('user32.dll')
        desktop = Fiddle::Function.new(user32['GetDesktopWindow'], [], Fiddle::TYPE_VOIDP)
        get_window = Fiddle::Function.new(
          user32['GetWindow'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
          Fiddle::TYPE_VOIDP
        )
        hwnd = get_window.call(desktop.call, GW_CHILD)
        while hwnd && hwnd.to_i != 0
          yield hwnd.to_i
          hwnd = get_window.call(hwnd, GW_HWNDNEXT)
        end
      rescue StandardError
        nil
      end
      private_class_method :each_top_level_hwnd

      def window_class(hwnd)
        require 'fiddle'
        user32 = Fiddle.dlopen('user32.dll')
        get_class = Fiddle::Function.new(
          user32['GetClassNameW'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
          Fiddle::TYPE_INT
        )
        buf = Fiddle::Pointer.malloc(512)
        len = get_class.call(Fiddle::Pointer.new(hwnd.to_i), buf, 256).to_i
        return '' if len <= 0

        raw = buf.respond_to?(:to_str) ? buf.to_str(len * 2) : buf.to_s(len * 2)
        raw.force_encoding('UTF-16LE').encode('UTF-8')
      rescue StandardError
        ''
      end
      private_class_method :window_class

      def window_area(hwnd)
        require 'fiddle'
        user32 = Fiddle.dlopen('user32.dll')
        fn = Fiddle::Function.new(
          user32['GetWindowRect'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
          Fiddle::TYPE_INT
        )
        rect = Fiddle::Pointer.malloc(16)
        return 0 if fn.call(Fiddle::Pointer.new(hwnd.to_i), rect).to_i == 0

        left, top, right, bottom = rect[0, 16].unpack('l4')
        width = right - left
        height = bottom - top
        return 0 if width <= 0 || height <= 0

        width * height
      rescue StandardError
        0
      end
      private_class_method :window_area

      def window_iconic?(hwnd)
        require 'fiddle'
        user32 = Fiddle.dlopen('user32.dll')
        fn = Fiddle::Function.new(user32['IsIconic'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
        fn.call(Fiddle::Pointer.new(hwnd.to_i)).to_i != 0
      rescue StandardError
        false
      end
      private_class_method :window_iconic?

      def dialog_hwnd
        if @dialog_hwnd && @dialog_hwnd != 0 && window_alive?(@dialog_hwnd)
          return @dialog_hwnd
        end

        found = find_dialog_hwnd
        @dialog_hwnd = found if found && found != 0
        @dialog_hwnd
      end
      private_class_method :dialog_hwnd

      def find_dialog_hwnd
        require 'fiddle'
        user32 = Fiddle.dlopen('user32.dll')
        find = Fiddle::Function.new(
          user32['FindWindowW'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
          Fiddle::TYPE_VOIDP
        )
        hwnd = find.call(0, utf16_ptr(TITLE))
        hwnd_i = hwnd.to_i
        return hwnd_i if hwnd_i != 0 && window_pid(hwnd_i) == Process.pid

        walk_dialog_hwnd(user32)
      rescue StandardError
        nil
      end
      private_class_method :find_dialog_hwnd

      def walk_dialog_hwnd(user32)
        get_fore = Fiddle::Function.new(user32['GetForegroundWindow'], [], Fiddle::TYPE_VOIDP)
        get_window = Fiddle::Function.new(
          user32['GetWindow'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
          Fiddle::TYPE_VOIDP
        )
        seed = get_fore.call
        return nil if seed.nil? || seed.to_i == 0

        gw_hwndfirst = 0
        gw_hwndnext = 2
        hwnd = get_window.call(seed, gw_hwndfirst)
        seen = {}
        while hwnd && hwnd.to_i != 0 && !seen[hwnd.to_i]
          seen[hwnd.to_i] = true
          hwnd_i = hwnd.to_i
          if window_visible?(hwnd_i) && window_pid(hwnd_i) == Process.pid && dialog_title?(window_title(hwnd_i))
            return hwnd_i
          end

          hwnd = get_window.call(hwnd, gw_hwndnext)
        end
        nil
      end
      private_class_method :walk_dialog_hwnd

      def window_alive?(hwnd)
        require 'fiddle'
        user32 = Fiddle.dlopen('user32.dll')
        fn = Fiddle::Function.new(user32['IsWindow'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
        fn.call(Fiddle::Pointer.new(hwnd)).to_i != 0
      rescue StandardError
        false
      end
      private_class_method :window_alive?

      def window_visible?(hwnd)
        require 'fiddle'
        user32 = Fiddle.dlopen('user32.dll')
        fn = Fiddle::Function.new(user32['IsWindowVisible'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
        fn.call(Fiddle::Pointer.new(hwnd)).to_i != 0
      rescue StandardError
        false
      end
      private_class_method :window_visible?

      def window_pid(hwnd)
        require 'fiddle'
        user32 = Fiddle.dlopen('user32.dll')
        get_tid = Fiddle::Function.new(
          user32['GetWindowThreadProcessId'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
          Fiddle::TYPE_INT
        )
        buf = Fiddle::Pointer.malloc(8)
        buf[0, 8] = 0.chr * 8
        get_tid.call(Fiddle::Pointer.new(hwnd), buf)
        buf[0, 4].unpack('L').first.to_i
      rescue StandardError
        0
      end
      private_class_method :window_pid

      def window_title(hwnd)
        require 'fiddle'
        user32 = Fiddle.dlopen('user32.dll')
        get_text = Fiddle::Function.new(
          user32['GetWindowTextW'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
          Fiddle::TYPE_INT
        )
        buf = Fiddle::Pointer.malloc(1024)
        len = get_text.call(Fiddle::Pointer.new(hwnd), buf, 256).to_i
        return '' if len <= 0

        raw = buf.respond_to?(:to_str) ? buf.to_str(len * 2) : buf.to_s(len * 2)
        raw.force_encoding('UTF-16LE').encode('UTF-8')
      rescue StandardError
        ''
      end
      private_class_method :window_title

      def dialog_title?(text)
        title = text.to_s.strip
        title == TITLE || title.start_with?(TITLE)
      end
      private_class_method :dialog_title?

      def utf16_ptr(text)
        require 'fiddle'
        data = text.to_s.encode('UTF-16LE') << "\0".encode('UTF-16LE')
        ptr = Fiddle::Pointer.malloc(data.bytesize)
        ptr[0, data.bytesize] = data.dup.force_encoding('ASCII-8BIT')
        ptr
      end
      private_class_method :utf16_ptr

      def load_html!(dialog)
        html = File.read(HTML_PATH)
        html.force_encoding('UTF-8') if html.respond_to?(:force_encoding)
        dialog.set_html(html)
        @html_mtime = html_mtime
      end
      private_class_method :load_html!

      def html_mtime
        File.mtime(HTML_PATH).to_i
      rescue StandardError
        0
      end
      private_class_method :html_mtime

      def reload_html_if_changed!
        return unless @dialog
        return if @html_mtime.to_i == html_mtime

        load_html!(@dialog)
        UI.start_timer(0.25, false) { sync_boot if visible? }
      rescue StandardError
        nil
      end
      private_class_method :reload_html_if_changed!

      def host_file
        File.join(Session.user_data_dir, 'plugin_host.json')
      end
      private_class_method :host_file

      def host_pid
        path = host_file
        return nil unless File.exist?(path)

        parsed = JSON.parse(File.read(path).to_s)
        pid = parsed.is_a?(Hash) ? parsed['pid'].to_i : 0
        pid > 0 ? pid : nil
      rescue StandardError
        nil
      end
      private_class_method :host_pid

      def claim_host!
        FileUtils.mkdir_p(File.dirname(host_file))
        File.open(host_file, 'w') { |file| file.write(JSON.generate('pid' => Process.pid, 'at' => Time.now.to_i)) }
      rescue StandardError
        nil
      end
      private_class_method :claim_host!

      def release_host!
        return unless host_pid == Process.pid

        File.delete(host_file) if File.exist?(host_file)
      rescue StandardError
        nil
      end
      private_class_method :release_host!

      def host_alive?(pid)
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
      private_class_method :host_alive?

      def visible?
        !!(@dialog && @dialog.visible?)
      end

      def push(event, payload)
        return unless visible?

        json = JSON.generate(payload)
        @dialog.execute_script("SkpDbUI.onEvent(#{event.to_json}, #{json});")
      end

      def register_callbacks(dialog)
        dialog.add_action_callback('ready') { sync_boot }

        dialog.add_action_callback('login') do |_ctx, json|
          run_action('login') do
            data = parse_json(json)
            if data['apiBase'].to_s.strip != ''
              Session.api_base = data['apiBase']
              Api.reset_client!
            end
            result = Api.login(data['email'], data['password'])
            sync_after_auth(result)
          end
        end

        dialog.add_action_callback('logout') do
          run_action('logout') do
            Api.logout
            push('session', { ok: false, email: Session.email, apiBase: Session.api_base })
          end
        end

        dialog.add_action_callback('refresh') do |_ctx, json|
          run_action('refresh') do
            push_open_models
            load_list(parse_json(json))
          end
        end

        dialog.add_action_callback('set_content_type') do |_ctx, code|
          run_action('refresh') do
            Session.content_type = code.to_s
            sync_after_auth({ ok: true, email: Session.email })
          end
        end

        dialog.add_action_callback('refresh_open_models') do
          push_open_models
        end

        dialog.add_action_callback('activate_model') do |_ctx, object_id|
          ModelIndex.activate(object_id)
          push_open_models
          selected = ModelIndex.summaries.find { |item| item[:objectId].to_s == object_id.to_s }
          push('modelName', { name: selected[:name] }) if selected
        end

        dialog.add_action_callback('open_item') do |_ctx, raw|
          run_action('open') do
            data = parse_open_payload(raw)
            result = Transfer.open_content(
              data['id'],
              catalog_name: data['name'],
              status: data['status'],
              group_id: data['groupId'] || data['group_id'],
              labels: data['labels']
            )
            push('opened', result)
            push_open_models
            [0.4, 2.0, 5.0, 8.0].each do |delay|
              UI.start_timer(delay, false) { push_open_models if visible? }
            end
            Sketchup.status_text = "ConstrTodo: открыт #{result[:filename]}"
            result
          end
        end

        dialog.add_action_callback('upload_new') do |_ctx, json|
          run_action('upload') do
            data = parse_json(json)
            result = Transfer.upload_current(data)
            load_list({})
            push_open_models
            push('modelName', { name: result[:filename].to_s.sub(/\.skp\z/i, '') })
            push('uploaded', result.merge(mode: result[:mode] || result['mode'] || 'create'))
            Sketchup.status_text = "ConstrTodo: отправлен #{result[:filename]}"
            result
          end
        end

        dialog.add_action_callback('upload_version') do |_ctx, json|
          run_action('upload') do
            data = parse_json(json)
            group_id = data['groupId'] || data['group_id']
            raise 'Не выбран документ для новой версии' if group_id.to_s.strip.empty?

            result = Transfer.upload_current(data, group_id: group_id)
            load_list({})
            push_open_models
            push('modelName', { name: result[:filename].to_s.sub(/\.skp\z/i, '') })
            push('uploaded', result.merge(mode: 'version'))
            Sketchup.status_text = "ConstrTodo: новая версия #{result[:filename]}"
            result
          end
        end

        dialog.add_action_callback('refresh_form') do |_ctx, json|
          begin
            push('form', Api.form_schema_for_ui(parse_json(json)))
          rescue StandardError => e
            push('error', { name: 'form', error: e.message })
          end
        end

        dialog.add_action_callback('model_name') do
          push_model_name
        end
      end
      private_class_method :register_callbacks

      def push_open_models
        return unless visible?

        push('openModels', { ok: true, items: ModelIndex.summaries })
      rescue StandardError => e
        push('openModels', { ok: false, items: [], error: e.message })
      end
      module_function :push_open_models

      def push_model_name
        push('modelName', { name: Transfer.current_model_name })
        push_open_models
      end
      private_class_method :push_model_name

      def schedule_model_name!
        UI.start_timer(0.3, false) { push_model_name if visible? }
        UI.start_timer(1.0, false) { push_model_name if visible? }
      end
      private_class_method :schedule_model_name!

      def sync_boot
        push('boot', {
          ok: true,
          version: VERSION,
          email: Session.email,
          apiBase: Session.api_base,
          modelName: Transfer.current_model_name,
          contentType: Session.content_type,
          platform: ::Constrtodo::SkpDb.platform_code,
          sketchupVersion: Sketchup.version.to_s
        })
        push_open_models
        return unless Session.logged_in?

        info = Api.session_info
        if info[:ok]
          sync_after_auth(info)
        else
          push('session', { ok: false, email: Session.email, apiBase: Session.api_base, error: info[:error] })
        end
        schedule_model_name!
      end
      private_class_method :sync_boot

      def sync_after_auth(info)
        info = {} unless info.is_a?(Hash)
        payload = {
          ok: true,
          version: VERSION,
          apiBase: Session.api_base,
          email: Session.email
        }.merge(info)
        push('session', payload)
        push('types', Api.content_types_for_ui)
        push('form', Api.form_schema_for_ui)
        push_open_models
        load_list({})
      end
      private_class_method :sync_after_auth

      def load_list(filters)
        result = Api.list_models(filters)
        push('list', result)
        result
      end
      private_class_method :load_list

      def run_action(name)
        push('busy', { name: name, busy: true })
        begin
          yield
        rescue StandardError => e
          message = e.message.to_s
          message = e.class.name if message.empty?
          puts "[SkpDb] #{name} failed: #{message}"
          puts e.backtrace.first(12)
          push('busy', { name: name, busy: false })
          push('error', { name: name, error: message })
          Sketchup.status_text = "ConstrTodo: #{message}"
          return
        end
        push('busy', { name: name, busy: false })
      end
      private_class_method :run_action

      def parse_open_payload(raw)
        if raw.is_a?(Hash)
          payload = stringify_payload(raw)
          payload['id'] = payload['id'] || payload['contentId'] || payload['content_id']
          return payload
        end

        text = raw.to_s.strip
        if text.start_with?('{')
          payload = parse_json(text)
          unless payload.empty?
            payload['id'] = payload['id'] || payload['contentId'] || payload['content_id']
            return payload
          end
        end

        { 'id' => text, 'name' => '' }
      end
      private_class_method :parse_open_payload

      def parse_json(raw)
        case raw
        when Hash
          stringify_payload(raw)
        when nil
          {}
        else
          text = raw.to_s
          return {} if text.empty?

          parsed = JSON.parse(text)
          parsed.is_a?(Hash) ? parsed : {}
        end
      rescue JSON::ParserError
        {}
      end
      private_class_method :parse_json

      def stringify_payload(obj)
        return obj unless obj.is_a?(Hash)

        obj.each_with_object({}) do |(key, value), acc|
          acc[key.to_s] = value
        end
      end
      private_class_method :stringify_payload
    end

  end
end
