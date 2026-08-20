require 'fileutils'
require 'tmpdir'

module Constrtodo
  module SkpDb

    module Transfer
      module_function

      def open_content(content_id)
        content = Api.get_content(content_id)
        file = Api.find_skp_file(content)
        raise 'В карточке нет файла SketchUp (download_url)' if file.nil? || file[:url].to_s.empty?

        downloaded = Api.download_file(file[:url])
        filename = safe_filename(downloaded[:filename] || file[:name], "model_#{content_id}.skp")
        path = File.join(work_dir, filename)
        File.binwrite(path, downloaded[:data])

        opened = open_skp(path)
        {
          ok: true,
          path: path,
          filename: filename,
          opened: opened
        }
      end

      def upload_current(values = {}, group_id: nil)
        values = stringify(values)
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
        result = if group_id.to_s.strip.empty?
                   Api.create_content(form)
                 else
                   Api.create_version(group_id, form)
                 end
        log("upload ok: #{result.inspect[0, 300]}")
        renamed = rename_sent_model!(model, filename)

        {
          ok: true,
          contentId: result_id(result, 'content_id', 'id'),
          groupId: result_id(result, 'group_id') || group_id,
          filename: filename,
          path: renamed || path
        }
      end

      def resolve_model(object_id)
        model = ModelIndex.find(object_id) if object_id.to_s != ''
        model ||= Sketchup.active_model
        raise 'Нет открытой модели SketchUp' if model.nil?

        active = Sketchup.active_model
        if active && model.object_id != active.object_id
          raise "Выбранная модель не активна. Кликните её окно в SketchUp и повторите отправку (#{ModelIndex.display_name(model)})."
        end
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
        dir = File.join(Sketchup.temp_dir, 'constrtodo_skpdb')
        FileUtils.mkdir_p(dir)
        dir
      end

      def safe_filename(name, fallback)
        base = File.basename(name.to_s)
        base = fallback if base.empty?
        base = base.gsub(/[^\w.\-А-Яа-яЁё ]+/, '_')
        base = "#{base}.skp" unless base.downcase.end_with?('.skp')
        base
      end

      def open_skp(path)
        Sketchup.open_file(path)
        true
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
