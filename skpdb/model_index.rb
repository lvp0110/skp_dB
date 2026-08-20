module Constrtodo
  module SkpDb

    # На Mac SketchUp держит несколько окон, но API отдаёт только active_model.
    # Копим модели через AppObserver и показываем их списком.
    module ModelIndex
      @models = {}
      @attached = false

      module_function

      def attach!
        return if @attached

        Sketchup.add_observer(Observer.new)
        remember(Sketchup.active_model)
        @attached = true
      end

      def remember(model)
        return if model.nil?

        @models[model.object_id] = model
        prune!
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
        model = @models[object_id.to_i]
        return model if alive?(model)

        active = Sketchup.active_model
        return active if active && active.object_id == object_id.to_i

        nil
      end

      def summaries
        active = Sketchup.active_model
        all.map { |model| summary(model, active) }
      end

      def summary(model, active = nil)
        active ||= Sketchup.active_model
        {
          objectId: model.object_id,
          name: display_name(model),
          path: display_path(model),
          active: !!(active && model.object_id == active.object_id),
          modified: model.respond_to?(:modified?) ? !!model.modified? : false,
          entities: model.entities.count
        }
      rescue StandardError => e
        {
          objectId: model.object_id,
          name: "Модель #{model.object_id}",
          path: '',
          active: false,
          modified: false,
          entities: 0,
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

      def placeholder_title?(name)
        %w[untitled untitled.skp sketchup model без имени новая модель].include?(name.to_s.strip.downcase)
      end

      class Observer < Sketchup::AppObserver
        def expectsStartupModelNotifications
          true
        end

        def onNewModel(model)
          ModelIndex.prune!
          ModelIndex.remember(model)
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
      end
    end

  end
end
