require 'fileutils'
require 'tmpdir'
require 'json'
require 'cgi'

module Constrtodo
  module SkpDb

    module Transfer
      module_function

      def open_content(content_id, catalog_name: nil, status: nil, group_id: nil)
        content = Api.get_content(content_id)
        meta = content_meta(content, 'id' => content_id, 'status' => status, 'groupId' => group_id, 'name' => catalog_name)
        existing = ModelIndex.window_for_content(meta[:id])
        if existing
          ModelIndex.activate(existing[:objectId])
          log("open_content reuse window #{meta[:id]} #{existing[:objectId]}")
          return {
            ok: true,
            alreadyOpen: true,
            filename: existing[:name] || meta[:name],
            mode: existing[:catalogMode] || (draft_status?(meta[:status]) ? 'edit' : 'view'),
            status: meta[:status]
          }
        end

        file = Api.find_skp_file(content)
        raise 'В карточке нет файла SketchUp (download_url)' if file.nil? || file[:url].to_s.empty?

        downloaded = Api.download_file(file[:url])
        filename = catalog_filename(content, meta[:name], downloaded[:filename], file[:name], content_id)
        path = catalog_open_path(content_id, filename)
        writable = draft_status?(meta[:status])
        write_model_file(path, downloaded[:data], writable: writable)
        raise 'Скачанный файл пуст' unless File.exist?(path) && File.size(path) > 50

        binding = {
          'contentId' => meta[:id].to_s,
          'groupId' => meta[:groupId].to_s,
          'status' => meta[:status].to_s,
          'mode' => writable ? 'edit' : 'view',
          'path' => File.expand_path(path),
          'name' => filename.sub(/\.skp\z/i, '')
        }
        ModelIndex.bind_catalog(binding)
        log("open_content id=#{content_id} mode=#{binding['mode']} saved=#{path}")

        opened = open_skp(path, filename: filename)
        {
          ok: true,
          path: path,
          filename: filename,
          opened: opened,
          mode: binding['mode'],
          status: meta[:status]
        }
      end

      def upload_current(values = {}, group_id: nil)
        values = stringify(values)
        object_id = values['modelObjectId'] || values['objectId']
        if object_id.to_s != '' && ModelIndex.remote?(object_id) && !truthy?(values['useActive'])
          pid = ModelIndex.pid_for(object_id)
          raise 'Не найдено окно выбранной модели' if pid.to_i <= 0

          payload = values.merge('modelObjectId' => '', 'objectId' => '', 'useActive' => true)
          request_command(pid, group_id.to_s.strip.empty? ? 'upload_new' : 'upload_version', payload, group_id)
          ModelIndex.activate(object_id)
          return {
            ok: true,
            delegated: true,
            mode: 'delegated',
            filename: display_filename(values['name']).sub(/\.skp\z/i, '')
          }
        end
        fields_schema = begin
                          Api.resolved_form_fields(values)
                        rescue StandardError => e
                          log("form_schema: #{e.message}")
                          raise "Не получена форма типа #{Api.content_type}: #{e.message}"
                        end
        model = resolve_model(values['modelObjectId'] || values['objectId'])
        sent_name = upload_name(values, model)
        filename = display_filename(sent_name)
        path = save_current_model(sent_name, model: model)
        log("saved #{path} as #{filename} (#{File.size(path)} bytes) schema=#{fields_schema.map { |f| field_code(f) }.join(',')}")
        binary = File.binread(path)

        form = build_form(fields_schema, values, filename: filename, data: binary)
        log("form keys: #{form.keys.join(', ')} scalars=#{Api.scalar_field_keys(form).join(',')}")
        content_id = values['catalogContentId']
        result = if values['saveMode'].to_s == 'update' && content_id.to_s != ''
                   Api.update_content(content_id, form)
                 elsif group_id.to_s.strip.empty?
                   Api.create_content(form)
                 else
                   Api.create_version(group_id, form)
                 end
        log("upload ok: #{result.inspect[0, 300]}")
        renamed = rename_sent_model!(model, filename)

        save_mode = if values['saveMode'].to_s == 'update' && content_id.to_s != ''
                      'update'
                    elsif group_id.to_s.strip.empty?
                      'create'
                    else
                      'version'
                    end
        {
          ok: true,
          contentId: result_id(result, 'content_id', 'id') || content_id,
          groupId: result_id(result, 'group_id') || group_id,
          filename: filename,
          path: renamed || path,
          mode: save_mode
        }
      end

      def resolve_model(object_id)
        return Sketchup.active_model if object_id.to_s == '' || object_id.to_s == 'active'

        if ModelIndex.remote?(object_id)
          raise 'Эта модель открыта в другом окне SketchUp. Кликните её в списке окон.'
        end

        model = ModelIndex.find(object_id) if object_id.to_s != ''
        model ||= Sketchup.active_model
        raise 'Нет открытой модели SketchUp' if model.nil?

        model
      end

      def current_model_name
        model = Sketchup.active_model
        return fallback_model_name if model.nil?

        names = []
        names << ModelIndex.human_name(model.title.to_s, model.path.to_s)
        path = model.path.to_s.strip
        names << File.basename(path, '.*') unless path.empty? || ModelIndex.temp_path?(path)

        sel = model.selection
        if sel && sel.length == 1 && sel.first.respond_to?(:definition)
          names << sel.first.definition.name.to_s.strip
        end

        names.each do |name|
          next if name.empty?
          next if placeholder_name?(name)
          return name
        end

        fallback_model_name
      end

      def placeholder_name?(name)
        normalized = name.to_s.strip.downcase
        ['sketchup model', 'untitled', 'untitled.skp', 'без имени', 'новая модель'].include?(normalized)
      end

      def fallback_model_name
        Time.now.strftime('Модель %Y-%m-%d %H-%M')
      end

      def upload_name(values, model)
        NAME_FIELD_CODES.each do |code|
          value = values[code].to_s.strip
          next if value.empty? || placeholder_name?(value) || looks_like_path?(value)

          return ModelIndex.basename_if_path(value)
        end
        ModelIndex.display_name(model)
      end

      def looks_like_path?(value)
        text = value.to_s
        text.include?('/var/folders/') || text.include?('constrtodo_skpdb') || text.start_with?('/') && text.downcase.end_with?('.skp')
      end

      def save_current_model(name = nil, model: nil)
        model ||= Sketchup.active_model
        raise 'Нет активной модели SketchUp' if model.nil?

        filename = display_filename(name)
        dest = File.join(work_dir, filename)
        current = model.path.to_s
        if !current.empty? && File.exist?(current) && same_path?(current, dest)
          model.save if model.respond_to?(:modified?) && model.modified?
          return current if File.size(current) > 50
        end
        dest = unique_path(dest) if File.exist?(dest)

        saved = try_save_copy(model, dest)
        saved ||= try_copy_existing(model, dest)
        saved ||= try_save(model, dest)

        unless saved && File.exist?(dest) && File.size(dest) > 50
          raise 'Не удалось сохранить текущую модель в временный .skp. Сохраните её через «Файл → Сохранить» и повторите отправку.'
        end

        dest
      end

      def rename_sent_model!(model, filename)
        return nil if model.nil?

        current = model.path.to_s
        return current unless current.empty? || ModelIndex.temp_path?(current)

        dest = File.join(work_dir, File.basename(filename))
        dest = unique_path(dest) if File.exist?(dest) && !same_path?(current, dest)
        return current if !current.empty? && same_path?(current, dest)

        saved = false
        saved = model.save(dest) if model.respond_to?(:save)
        log("rename sent model #{current.inspect} -> #{dest} saved=#{saved}")
        return dest if saved && File.exist?(dest)

        current
      rescue StandardError => e
        log("rename sent model: #{e.message}")
        nil
      end

      def same_path?(left, right)
        File.expand_path(left.to_s) == File.expand_path(right.to_s)
      rescue StandardError
        left.to_s == right.to_s
      end

      def unique_path(path)
        return path unless File.exist?(path)

        dir = File.dirname(path)
        ext = File.extname(path)
        base = File.basename(path, ext)
        index = 2
        loop do
          candidate = File.join(dir, "#{base} #{index}#{ext}")
          return candidate unless File.exist?(candidate)

          index += 1
        end
      end

      def try_save_copy(model, dest)
        return false unless model.respond_to?(:save_copy)
        return false unless model.save_copy(dest)

        File.exist?(dest) && File.size(dest) > 50
      rescue StandardError => e
        log("save_copy: #{e.message}")
        false
      end

      def try_copy_existing(model, dest)
        src = model.path.to_s
        return false if src.empty? || !File.exist?(src)

        model.save if model.respond_to?(:modified?) && model.modified?
        FileUtils.cp(src, dest)
        File.exist?(dest) && File.size(dest) > 50
      rescue StandardError => e
        log("copy existing: #{e.message}")
        false
      end

      def try_save(model, dest)
        return false unless model.save(dest)

        File.exist?(dest) && File.size(dest) > 50
      rescue StandardError => e
        log("save: #{e.message}")
        false
      end

      def display_filename(name)
        base = name.to_s.strip
        base = current_model_name if base.empty?
        safe_filename("#{base}.skp", 'model.skp')
      end

      def result_id(result, *keys)
        return nil unless result.is_a?(Hash)

        keys.each do |key|
          value = result[key] || result[key.to_s] || result[key.to_sym]
          return value unless value.nil? || value.to_s.empty?
        end
        nil
      end

      def log(message)
        path = File.join(work_dir, 'debug.log')
        File.open(path, 'a') { |file| file.puts("#{Time.now}: #{message}") }
        puts "[SkpDb] #{message}"
      rescue StandardError
        nil
      end

      def work_dir
        dir = File.expand_path(File.join(Sketchup.temp_dir, 'constrtodo_skpdb'))
        FileUtils.mkdir_p(dir)
        dir
      end

      def safe_filename(name, fallback)
        base = File.basename(name.to_s.tr('\\', '/'))
        if base.include?('%')
          begin
            base = CGI.unescape(base)
          rescue StandardError
            nil
          end
        end
        base = fallback if base.empty? || generic_download_name?(base)
        base = base.gsub(/[<>:"\/\\|?*\x00-\x1f]+/, '_').gsub(/[. ]+\z/, '')
        base = fallback if base.empty?
        base = base[0, 120]
        base = "#{base}.skp" unless base.downcase.end_with?('.skp')
        base
      end

      def content_meta(content, fallbacks = {})
        fallbacks = stringify(fallbacks)
        hash = stringify(content)
        payload = hash['payload'] || hash['data'] || hash
        payload = stringify(payload) if payload.is_a?(Hash)
        status = (hash['status'] || fallbacks['status']).to_s.downcase
        {
          id: hash['id'] || fallbacks['id'],
          groupId: hash['group_id'] || hash['groupId'] || fallbacks['groupId'] || hash['id'] || fallbacks['id'],
          status: status,
          name: pick_catalog_name(fallbacks['name'], hash['name'], hash['title'], payload.is_a?(Hash) ? payload['name'] : nil)
        }
      end

      def draft_status?(status)
        text = status.to_s.strip.downcase
        text == 'draft' || text == 'черновик'
      end

      def catalog_open_path(content_id, filename)
        File.join(work_dir, "c#{content_id}_#{filename}")
      end

      def write_model_file(path, data, writable:)
        if File.exist?(path)
          begin
            File.chmod(0o644, path)
          rescue StandardError
            nil
          end
        end
        File.binwrite(path, data)
        unless writable
          begin
            File.chmod(0o444, path)
          rescue StandardError
            nil
          end
        end
      end

      def catalog_filename(content, catalog_name, download_name, file_name, content_id)
        picked = pick_catalog_name(
          catalog_name,
          content_title(content),
          file_name,
          download_name
        )
        safe_filename(picked, "model_#{content_id}.skp")
      end

      def content_title(content)
        hash = stringify(content)
        payload = hash['payload'] || hash['data'] || hash
        payload = stringify(payload) if payload.is_a?(Hash)
        pick_catalog_name(
          hash['name'], hash['Name'], hash['title'], hash['header'],
          payload.is_a?(Hash) ? payload['name'] : nil,
          payload.is_a?(Hash) ? payload['title'] : nil,
          payload.is_a?(Hash) ? payload['header'] : nil
        )
      end

      def pick_catalog_name(*candidates)
        candidates.flatten.each do |value|
          text = value.to_s.strip
          next if text.empty?
          next if placeholder_name?(text)
          next if looks_like_path?(text)
          next if generic_download_name?(text)

          return ModelIndex.basename_if_path(text)
        end
        nil
      end

      def generic_download_name?(name)
        text = File.basename(name.to_s.tr('\\', '/')).sub(/\.skp\z/i, '').strip.downcase
        return true if text.empty?
        return true if %w[model file download attachment untitled sketchup].include?(text)
        return true if text =~ /\A(model|download|file|content)[_-]?\d+\z/
        return true if text =~ /\A[0-9a-f-]{16,}\z/

        false
      end

      def open_skp(path, filename: nil)
        path = File.expand_path(path.to_s)
        raise 'Файл модели не найден' unless File.exist?(path)

        if ::Constrtodo::SkpDb.osx?
          open_skp_in_app(path)
        else
          open_skp_new_window(path, filename)
        end
      end

      def open_skp_in_app(path)
        status = begin
          Sketchup.open_file(path, with_status: true)
        rescue ArgumentError
          Sketchup.open_file(path)
          true
        end

        return true if status == true

        success = []
        success << Sketchup::Model::LOAD_STATUS_SUCCESS if defined?(Sketchup::Model::LOAD_STATUS_SUCCESS)
        success << Sketchup::Model::LOAD_STATUS_SUCCESS_MORE_RECENT if defined?(Sketchup::Model::LOAD_STATUS_SUCCESS_MORE_RECENT)
        return true if success.include?(status)
        return true if success.empty? && status

        raise 'Открытие файла отменено' if status == false || status.nil?
        raise "Не удалось открыть модель в SketchUp (статус #{status})."
      end

      def open_skp_new_window(path, filename)
        title = filename.to_s.sub(/\.skp\z/i, '')
        title = File.basename(path, '.*') if title.empty?
        write_pending_open(path, title)
        ModelIndex.announce_opening(path, title)
        launched = launch_new_sketchup_process(path)
        log("launch_new_sketchup_process=#{launched} exe=#{sketchup_executable.inspect} file=#{path}")
        raise 'Не удалось открыть модель в новом окне SketchUp.' unless launched

        true
      end

      def consume_pending_open!
        pending = read_pending_open
        log("consume_pending pid=#{Process.pid} consumed=#{@consumed_pending} pending=#{pending.inspect}")
        return false if @consumed_pending
        return false unless pending.is_a?(Hash)
        return false if pending['openerPid'].to_i == Process.pid
        return false if Time.now.to_i - pending['createdAt'].to_i > 120

        path = File.expand_path(pending['path'].to_s)
        unless File.exist?(path) && path.downcase.end_with?('.skp')
          log("consume_pending missing file #{path.inspect}")
          return false
        end

        if model_has_path?(path)
          @consumed_pending = true
          clear_pending_open
          log('consume_pending already open')
          return true
        end

        log("consume_pending open_file #{path}")
        open_skp_in_app(path)
        if model_has_path?(path)
          @consumed_pending = true
          clear_pending_open
          true
        else
          log('consume_pending open_file did not switch model, will retry')
          false
        end
      rescue StandardError => e
        log("consume_pending_open: #{e.message}")
        false
      end

      def model_has_path?(path)
        model = Sketchup.active_model
        return false if model.nil?

        current = model.path.to_s
        return false if current.empty?

        same_path?(current, path)
      rescue StandardError
        false
      end

      def launch_new_sketchup_process(skp_path)
        exe = sketchup_executable
        return false if exe.to_s.empty? || !File.exist?(exe)

        return true if create_process(exe, skp_path)
        return true if create_process(exe, nil)
        return true if cmd_start(exe)
        return true if win32ole_run_exe(exe)

        false
      end

      def sketchup_executable
        return @sketchup_executable if defined?(@sketchup_executable) && @sketchup_executable

        require 'fiddle'
        buf = Fiddle::Pointer.malloc(4096)
        kernel32 = Fiddle.dlopen('kernel32.dll')
        fn = Fiddle::Function.new(
          kernel32['GetModuleFileNameW'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
          Fiddle::TYPE_INT
        )
        length = fn.call(0, buf, 1024)
        return nil if length.to_i <= 0

        raw = buf.respond_to?(:to_str) ? buf.to_str(length * 2) : buf.to_s(length * 2)
        @sketchup_executable = raw.force_encoding('UTF-16LE').encode('UTF-8')
      rescue StandardError => e
        log("sketchup_executable: #{e.message}")
        nil
      end

      def create_process(exe, skp_path = nil)
        require 'fiddle'
        ptr_size = Fiddle::SIZEOF_VOIDP
        x64 = ptr_size == 8
        si_size = x64 ? 104 : 68
        kernel32 = Fiddle.dlopen('kernel32.dll')
        create = Fiddle::Function.new(
          kernel32['CreateProcessW'],
          [
            Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
            Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
            Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP
          ],
          Fiddle::TYPE_INT
        )
        closer = Fiddle::Function.new(kernel32['CloseHandle'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)

        si = Fiddle::Pointer.malloc(si_size)
        si[0, si_size] = 0.chr * si_size
        si[0, 4] = [si_size].pack('L')
        if x64
          si[60, 4] = [1].pack('L')
          si[64, 2] = [1].pack('S')
        else
          si[48, 4] = [1].pack('L')
          si[52, 2] = [1].pack('S')
        end

        pi = Fiddle::Pointer.malloc(32)
        pi[0, 32] = 0.chr * 32

        app = utf16_buf(win_path(exe))
        command = %("#{win_path(exe)}")
        if skp_path.to_s != '' && File.exist?(skp_path)
          command = %("#{win_path(exe)}" "#{win_path(skp_path)}")
        end
        cmd = utf16_buf(command)
        dir = utf16_buf(win_path(File.dirname((skp_path.to_s != '' && File.exist?(skp_path)) ? skp_path : exe)))
        ok = create.call(app, cmd, 0, 0, 0, 0, 0, dir, si, pi)
        log("CreateProcessW #{command.inspect} ok=#{ok}")
        if ok != 0
          h_process = unpack_handle(pi, 0, ptr_size)
          h_thread = unpack_handle(pi, ptr_size, ptr_size)
          begin
            closer.call(Fiddle::Pointer.new(h_process)) if h_process != 0
            closer.call(Fiddle::Pointer.new(h_thread)) if h_thread != 0
          rescue StandardError
            nil
          end
          return true
        end
        false
      rescue StandardError => e
        log("CreateProcessW: #{e.message}")
        false
      end

      def unpack_handle(pointer, offset, ptr_size)
        raw = pointer[offset, ptr_size]
        ptr_size == 8 ? raw.unpack('Q').first.to_i : raw.unpack('L').first.to_i
      end

      def cmd_start(exe)
        require 'win32ole'
        cmd = %(cmd /c start "" "#{win_path(exe)}")
        WIN32OLE.new('WScript.Shell').Run(cmd, 1, false)
        log("cmd start #{cmd}")
        true
      rescue StandardError => e
        log("cmd_start: #{e.message}")
        false
      end

      def win32ole_run_exe(exe)
        require 'win32ole'
        cmd = %("#{win_path(exe)}")
        WIN32OLE.new('WScript.Shell').Run(cmd, 1, false)
        log("WScript.Shell.Run #{cmd}")
        true
      rescue StandardError => e
        log("win32ole_run_exe: #{e.message}")
        false
      end

      def utf16_buf(text)
        data = text.to_s.encode('UTF-16LE') << "\0".encode('UTF-16LE')
        ptr = Fiddle::Pointer.malloc(data.bytesize)
        ptr[0, data.bytesize] = data.dup.force_encoding('ASCII-8BIT')
        ptr
      end

      def win_path(path)
        File.expand_path(path.to_s).tr('/', '\\')
      end

      def pending_open_path
        File.join(Session.user_data_dir, 'pending_open.json')
      end

      def command_path
        File.join(Session.user_data_dir, 'pending_command.json')
      end

      def request_command(pid, action, values = {}, group_id = nil)
        write_command_raw(
          'pid' => pid.to_i,
          'action' => action.to_s,
          'values' => values,
          'groupId' => group_id,
          'createdAt' => Time.now.to_i
        )
      end

      def consume_pending_command!
        cmd = read_command
        return false unless cmd.is_a?(Hash)
        return false if cmd['pid'].to_i != Process.pid
        return false if Time.now.to_i - cmd['createdAt'].to_i > 45

        clear_command
        action = cmd['action'].to_s
        if action == 'show'
          AppWindow.show
          return true
        end
        return true if action == 'focus'
        return false unless action == 'upload_new' || action == 'upload_version'

        UI.start_timer(0.5, false) do
          begin
            group_id = action == 'upload_version' ? cmd['groupId'] : nil
            result = upload_current(cmd['values'] || {}, group_id: group_id)
            AppWindow.push('uploaded', result.merge(mode: group_id.to_s.strip.empty? ? 'create' : 'version')) if AppWindow.visible?
            Sketchup.status_text = "ConstrTodo: отправлен #{result[:filename]}"
          rescue StandardError => e
            log("consume_pending_command: #{e.message}")
            AppWindow.push('error', { name: 'upload', error: e.message }) if AppWindow.visible?
            Sketchup.status_text = "ConstrTodo: #{e.message}"
          end
        end
        true
      rescue StandardError => e
        log("consume_pending_command: #{e.message}")
        false
      end

      def write_command_raw(payload)
        FileUtils.mkdir_p(File.dirname(command_path))
        File.open(command_path, 'w') { |file| file.write(JSON.generate(payload)) }
      rescue StandardError => e
        log("write_command: #{e.message}")
        nil
      end

      def read_command
        path = command_path
        return nil unless File.exist?(path)

        parsed = JSON.parse(File.read(path).to_s)
        parsed.is_a?(Hash) ? parsed : nil
      rescue StandardError
        nil
      end

      def clear_command
        File.delete(command_path) if File.exist?(command_path)
      rescue StandardError
        nil
      end

      def write_pending_open(path, name)
        write_pending_raw(
          'path' => File.expand_path(path.to_s),
          'name' => name.to_s,
          'openerPid' => Process.pid,
          'createdAt' => Time.now.to_i,
          'claimedBy' => 0
        )
      end

      def write_pending_raw(payload)
        FileUtils.mkdir_p(File.dirname(pending_open_path))
        File.open(pending_open_path, 'w') { |file| file.write(JSON.generate(payload)) }
      rescue StandardError => e
        log("write_pending_open: #{e.message}")
        nil
      end

      def read_pending_open
        path = pending_open_path
        return nil unless File.exist?(path)

        parsed = JSON.parse(File.read(path).to_s)
        parsed.is_a?(Hash) ? parsed : nil
      rescue StandardError
        nil
      end

      def clear_pending_open
        File.delete(pending_open_path) if File.exist?(pending_open_path)
      rescue StandardError
        nil
      end

      def pending_path_allowed?(path)
        text = path.to_s.downcase
        text.end_with?('.skp') && File.exist?(path)
      rescue StandardError
        false
      end

      def build_form(schema, values, filename:, data:)
        values = stringify(values)
        form = {}
        file_attached = false
        missing = []
        schema_fields = Array(schema)

        schema_fields.each do |field|
          field = stringify(field)
          code = field_code(field)
          next if code.empty? || code == 'privacy_group'

          type = (field['type'] || field['Type']).to_s
          required = truthy?(field['required']) || truthy?(field['Required']) || code == 'constr_code'

          if file_field?(type, code)
            form[code] = {
              filename: filename,
              data: data,
              mime: 'application/octet-stream'
            }
            file_attached = true
            next
          end

          value = value_for(code, values)
          value = default_text_value(code, values) if blank?(value) && (required || name_field?(code))
          if blank?(value)
            missing << code if required
            next
          end

          form[code] = value
        end

        merge_extra_values!(form, values)
        apply_field_aliases!(form, values)
        missing.delete('constr_code') unless blank?(form['constr_code'])

        unless file_attached
          file_code = guess_file_code(schema_fields)
          form[file_code] = {
            filename: filename,
            data: data,
            mime: 'application/octet-stream'
          }
        end

        if form.keys.none? { |key| name_field?(key) }
          name = values['name'].to_s.strip
          name = current_model_name if name.empty?
          form['name'] = name unless name.empty?
        end

        privacy = values['privacy_group'].to_s.strip
        privacy = 'public' if privacy.empty?
        form['privacy_group'] = privacy

        unless missing.empty?
          raise "Не отправлены обязательные поля: #{missing.join(', ')}. " \
                "В форме заполните поле с этим кодом (он указан мелким текстом под названием). " \
                "Сейчас в запросе: #{Api.scalar_field_keys(form).join(', ')}."
        end

        form
      end

      def field_code(field)
        hash = stringify(field)
        (hash['code'] || hash['Code'] || hash['key'] || hash['id']).to_s
      end

      def value_for(code, values)
        return values[code] unless blank?(values[code])

        Array(FIELD_CODE_ALIASES[code]).each do |alt|
          return values[alt] unless blank?(values[alt])
        end
        nil
      end

      def merge_extra_values!(form, values)
        values.each do |key, value|
          next if SKIP_UPLOAD_KEYS.include?(key.to_s)
          next if form.key?(key.to_s)
          next if value.is_a?(Hash)
          next if blank?(value)

          form[key.to_s] = value
        end
      end

      def apply_field_aliases!(form, values)
        FIELD_CODE_ALIASES.each do |canonical, alts|
          next unless blank?(form[canonical])

          alts.each do |alt|
            next if blank?(values[alt]) && blank?(form[alt])

            form[canonical] = values[alt] unless blank?(values[alt])
            form[canonical] = form[alt] if blank?(form[canonical]) && !blank?(form[alt])
            break unless blank?(form[canonical])
          end
        end
      end

      def guess_file_code(schema_fields)
        field = schema_fields.find do |item|
          item = stringify(item)
          file_field?(item['type'] || item['Type'], field_code(item))
        end
        field ? field_code(field) : 'file'
      end

      def file_field?(type, code)
        return true if FILE_FIELD_TYPES.include?(type.to_s)
        return true if type.to_s.empty? && %w[file skp sketchup_file model_file].include?(code.to_s)

        false
      end

      def name_field?(code)
        NAME_FIELD_CODES.include?(code.to_s)
      end

      def default_text_value(code, values)
        return values['name'] if name_field?(code) && !blank?(values['name'])
        return current_model_name if name_field?(code)

        nil
      end

      def stringify(obj)
        return obj unless obj.is_a?(Hash)

        obj.each_with_object({}) do |(key, value), acc|
          acc[key.to_s] = value
        end
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end

      def truthy?(value)
        value == true || value.to_s == 'true' || value.to_s == '1'
      end
    end

  end
end
