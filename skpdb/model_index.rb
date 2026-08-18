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
        path = model.path.to_s
        {
          objectId: model.object_id,
          name: display_name(model),
          path: path,
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
        title = model.title.to_s.strip
        path = model.path.to_s.strip
        base = path.empty? ? '' : File.basename(path, '.*')
        name = title.empty? || title.downcase == 'untitled' ? base : title
        name = "Без имени (#{model.entities.count} объектов)" if name.empty?
        name
      end

      class Observer < Sketchup::AppObserver
        def expectsStartupModelNotifications
          true
        end

        def onNewModel(model)
          ModelIndex.remember(model)
          AppWindow.push_open_models
        end

        def onOpenModel(model)
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
