require 'json'
require 'fileutils'

module Constrtodo
  module SkpDb

    module AppWindow
      TITLE = PLUGIN_NAME
      PREF_KEY = 'constrtodo_skpdb_window'.freeze

      @dialog = nil

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
          @dialog.show unless @dialog.visible?
          @dialog.bring_to_front
          push_open_models
          return
        end

        style = if defined?(UI::HtmlDialog::STYLE_WINDOW)
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
          @dialog = nil
          release_host!
        end
        @dialog.show
        schedule_model_name!
      end

      def load_html!(dialog)
        html = File.read(HTML_PATH)
        html.force_encoding('UTF-8') if html.respond_to?(:force_encoding)
        dialog.set_html(html)
      end
      private_class_method :load_html!

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
              group_id: data['groupId'] || data['group_id']
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
