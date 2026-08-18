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
        value.empty? ? CONTENT_TYPE_CODE : value
      end

      def content_type=(value)
        code = value.to_s.strip
        code = CONTENT_TYPE_CODE if code.empty?
        Sketchup.write_default(PLUGIN_ID, PREF_CONTENT_TYPE, code)
        code
      end

      def cookies
        return {} unless File.exist?(cookie_file)

        parsed = JSON.parse(File.read(cookie_file))
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      def cookies=(hash)
        FileUtils.mkdir_p(File.dirname(cookie_file))
        File.write(cookie_file, JSON.generate(hash || {}))
        Sketchup.write_default(PLUGIN_ID, PREF_COOKIES, '{}')
      rescue StandardError
        Sketchup.write_default(PLUGIN_ID, PREF_COOKIES, JSON.generate(hash || {}))
      end

      def clear!
        File.delete(cookie_file) if File.exist?(cookie_file)
        Sketchup.write_default(PLUGIN_ID, PREF_COOKIES, '{}')
      rescue StandardError
        Sketchup.write_default(PLUGIN_ID, PREF_COOKIES, '{}')
      end

      def logged_in?
        jar = cookies
        jar.key?('csrf_token') || jar.keys.any? { |key| key.to_s =~ /session|token|auth|sid/i }
      end

      def cookie_file
        File.join(MODULE_PATH, 'session.json')
      end
      private_class_method :cookie_file
    end

  end
end
