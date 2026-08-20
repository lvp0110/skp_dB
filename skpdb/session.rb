require 'json'
require 'fileutils'

module Constrtodo
  module SkpDb

    module Session
      module_function

      def api_base
        value = Sketchup.read_default(PLUGIN_ID, PREF_API_BASE, DEFAULT_API_BASE).to_s.strip
        value.empty? ? DEFAULT_API_BASE : value.sub(%r{/\z}, '')
      end

      def api_base=(url)
        value = url.to_s.strip.sub(%r{/\z}, '')
        value = DEFAULT_API_BASE if value.empty?
        Sketchup.write_default(PLUGIN_ID, PREF_API_BASE, value)
        value
      end

      def email
        Sketchup.read_default(PLUGIN_ID, PREF_EMAIL, '').to_s
      end

      def email=(value)
        Sketchup.write_default(PLUGIN_ID, PREF_EMAIL, value.to_s)
      end

      def content_type
        value = Sketchup.read_default(PLUGIN_ID, PREF_CONTENT_TYPE, CONTENT_TYPE_CODE).to_s.strip
        return CONTENT_TYPE_CODE if value.empty? || !::Constrtodo::SkpDb.sketchup_type_code?(value)

        value
      end

      def content_type=(value)
        code = value.to_s.strip
        code = CONTENT_TYPE_CODE if code.empty? || !::Constrtodo::SkpDb.sketchup_type_code?(code)
        Sketchup.write_default(PLUGIN_ID, PREF_CONTENT_TYPE, code)
        code
      end

      def cookies
        jar = read_json_hash(cookie_file)
        return jar unless jar.empty?

        jar = read_json_hash(legacy_cookie_file)
        unless jar.empty?
          begin
            self.cookies = jar
          rescue StandardError
            nil
          end
          return jar
        end

        cookies_from_prefs
      end

      def cookies=(hash)
        json = JSON.generate(hash || {})
        begin
          FileUtils.mkdir_p(user_data_dir)
          File.open(cookie_file, 'w') { |file| file.write(json) }
          delete_legacy_cookie_file
        rescue StandardError
          nil
        end
        begin
          Sketchup.write_default(PLUGIN_ID, PREF_COOKIES, json)
        rescue StandardError
          nil
        end
      end

      def clear!
        File.delete(cookie_file) if File.exist?(cookie_file)
        delete_legacy_cookie_file
        Sketchup.write_default(PLUGIN_ID, PREF_COOKIES, '{}')
      rescue StandardError
        Sketchup.write_default(PLUGIN_ID, PREF_COOKIES, '{}')
      end

      def logged_in?
        jar = cookies
        jar.key?('csrf_token') || jar.keys.any? { |key| key.to_s =~ /session|token|auth|sid/i }
      end

      def user_data_dir
        if ::Constrtodo::SkpDb.osx?
          home = ENV['HOME'].to_s
          return File.join(Sketchup.temp_dir, USER_DATA_DIR_NAME) if home.empty?

          File.join(home, 'Library', 'Application Support', USER_DATA_DIR_NAME)
        else
          appdata = ENV['APPDATA'].to_s
          return File.join(Sketchup.temp_dir, USER_DATA_DIR_NAME) if appdata.empty?

          File.join(appdata, USER_DATA_DIR_NAME)
        end
      end
      private_class_method :user_data_dir

      def cookie_file
        File.join(user_data_dir, 'session.json')
      end
      private_class_method :cookie_file

      def legacy_cookie_file
        File.join(MODULE_PATH, 'session.json')
      end
      private_class_method :legacy_cookie_file

      def delete_legacy_cookie_file
        path = legacy_cookie_file
        File.delete(path) if File.exist?(path)
      rescue StandardError
        nil
      end
      private_class_method :delete_legacy_cookie_file

      def read_json_hash(path)
        return {} unless path && File.exist?(path)

        raw = File.read(path).to_s
        return {} if raw.strip.empty?

        parsed = JSON.parse(raw)
        parsed.is_a?(Hash) ? parsed : {}
      rescue StandardError
        {}
      end
      private_class_method :read_json_hash

      def cookies_from_prefs
        raw = Sketchup.read_default(PLUGIN_ID, PREF_COOKIES, '{}').to_s
        return {} if raw.strip.empty? || raw == '{}'

        parsed = JSON.parse(raw)
        parsed.is_a?(Hash) ? parsed : {}
      rescue StandardError
        {}
      end
      private_class_method :cookies_from_prefs
    end

  end
end
