require 'json'
require 'uri'
require 'cgi'

module Constrtodo
  module SkpDb

    module Api
      module_function

      def client
        @client ||= HttpClient.new(Session.api_base).tap do |http|
          http.cookies = Session.cookies
        end
      end

      def reset_client!
        @client = nil
        @form_cache = nil
      end

      def login(email, password)
        reset_client!
        http = HttpClient.new(Session.api_base)
        response = http.post_json('login', email: email.to_s.strip, password: password.to_s)
        raise api_error_message(response) unless success?(response)

        Session.email = email.to_s.strip
        Session.cookies = http.cookies
        @client = http
        refresh_csrf!
        {
          ok: true,
          user: unwrap(response[:body]),
          email: Session.email
        }
      end

      def logout
        begin
          client.post_json('auth/logout', {}) if Session.logged_in?
        rescue StandardError
          nil
        end
        Session.clear!
        reset_client!
        { ok: true }
      end

      def session_info
        response = client.get('auth/session')
        unless success?(response)
          Session.clear!
          reset_client!
          return { ok: false, error: api_error_message(response) }
        end

        Session.cookies = client.cookies
        {
          ok: true,
          user: unwrap(response[:body]),
          email: Session.email,
          apiBase: Session.api_base
        }
      rescue StandardError => e
        { ok: false, error: e.message }
      end

      def list_models(filters = {})
        filters = {} unless filters.is_a?(Hash)
        type = filters['contentType'] || filters[:contentType] || content_type
        query = compact_query(filters)
        response = client.get("content/list/#{type}", query: query)
        raise api_error_message(response) unless success?(response)

        payload = unwrap(response[:body])
        persist_session!
        items = extract_list(payload)
        {
          ok: true,
          contentType: type,
          items: items.map { |item| normalize_list_item(item) },
          filters: extract_filters(payload),
          error: nil
        }
      rescue StandardError => e
        { ok: false, contentType: content_type, items: [], filters: [], error: e.message }
      end

      def get_content(id)
        response = client.get("content/#{id}")
        raise api_error_message(response) unless success?(response)

        unwrap(response[:body])
      end

      def form_schema(force: false, context: nil)
        type = content_type
        cache = (@form_cache ||= {})
        cache_key = [type, context_cache_key(context)]
        return cache[cache_key][:fields] if !force && context.nil? && cache[cache_key] && cache[cache_key][:fields]

        refresh_csrf!
        body = scalar_context(context)
        response = client.post_json("content/types/form/#{type}", body)
        persist_session!
        raise api_error_message(response) unless success?(response)

        payload = unwrap(response[:body])
        fields = extract_fields(payload).map { |field| normalize_form_field(field) }
        cache[cache_key] = { fields: fields, raw: payload } if context.nil?
        fields
      end

      def form_schema_for_ui(context = nil)
        fields = resolved_form_fields(context)
        {
          ok: true,
          contentType: content_type,
          fields: fields,
          error: nil
        }
      rescue StandardError => e
        { ok: false, contentType: content_type, fields: [], error: e.message }
      end

      def resolved_form_fields(context = nil)
        fields = form_schema(force: true, context: context).map { |field| enrich_field(field) }
        ensure_required_payload_fields(fields)
      end

      def scalar_field_keys(fields)
        (fields || {}).each_with_object([]) do |(key, value), acc|
          next if value.is_a?(Hash) && (value.key?(:data) || value.key?('data') || value.key?(:filename))

          acc << key.to_s
        end
      end

      def fetch_references(source, query = nil)
        source = source.to_s.strip
        return [] if source.empty?

        path = "content/references/#{source}"
        path = "#{path}?#{query}" if query.to_s.strip != '' && !query.to_s.include?('=')
        params = { filter: '', limit: 100, offset: 0 }
        extra = parse_query_string(query)
        params.merge!(extra) unless extra.empty?

        response = client.get(path, query: params)
        return [] unless success?(response)

        payload = unwrap(response[:body])
        list = extract_list(payload)
        list = payload if list.empty? && payload.is_a?(Array)
        Array(list).map { |item| normalize_option(item) }.reject { |item| item[:code].to_s.empty? }
      rescue StandardError
        []
      end

      def create_content(fields)
        refresh_csrf!
        response = client.post_form("content/#{content_type}", with_csrf(fields))
        persist_session!
        raise upload_error_message(response, fields) unless success?(response)

        unwrap(response[:body])
      end

      def create_version(group_id, fields)
        refresh_csrf!
        response = client.post_form("content/version/#{group_id}", with_csrf(fields))
        persist_session!
        raise upload_error_message(response, fields) unless success?(response)

        unwrap(response[:body])
      end

      def update_content(content_id, fields)
        refresh_csrf!
        last_error = nil
        [
          [:put, "content/#{content_id}"],
          [:post, "content/#{content_id}"],
          [:post, "content/update/#{content_id}"]
        ].each do |method, path|
          response = if method == :put
                       client.put_form(path, with_csrf(fields))
                     else
                       client.post_form(path, with_csrf(fields))
                     end
          persist_session!
          return unwrap(response[:body]) if success?(response)

          last_error = upload_error_message(response, fields)
          code = response[:code].to_i
          next if [404, 405, 501].include?(code)
          break
        end
        raise last_error || "Не удалось сохранить черновик #{content_id} в каталог"
      end

      def refresh_csrf!
        response = client.get('auth/session')
        persist_session!
        return if success?(response)

        raise "Сессия истекла, войдите снова (#{api_error_message(response)})"
      end

      def persist_session!
        Session.cookies = client.cookies
      rescue StandardError
        nil
      end

      def with_csrf(fields)
        token = client.csrf_token
        raise 'Нет CSRF-токена в cookie. Выйдите и войдите снова.' if token.empty?

        fields
      end

      def content_type
        Session.content_type
      end

      def content_types_for_ui
        response = client.get('content/types')
        raise api_error_message(response) unless success?(response)

        list = unwrap(response[:body])
        list = list['data'] if list.is_a?(Hash) && list['data'].is_a?(Array)
        items = Array(list).map { |item| normalize_content_type(item) }
        items = items.select { |item| sketchup_content_type?(item) }
        items = sketchup_type_fallbacks if items.empty?
        current = content_type
        unless items.any? { |item| item[:code] == current }
          Session.content_type = items.first[:code]
          current = content_type
        end
        {
          ok: true,
          current: current,
          items: items,
          error: nil
        }
      rescue StandardError => e
        {
          ok: false,
          current: content_type,
          items: sketchup_type_fallbacks,
          error: e.message
        }
      end

      def sketchup_type_code?(code)
        ::Constrtodo::SkpDb.sketchup_type_code?(code)
      end

      def sketchup_content_type?(item)
        item = stringify_keys(item) if item.is_a?(Hash)
        code = (item[:code] || item['code']).to_s
        name = (item[:name] || item['name']).to_s
        ::Constrtodo::SkpDb.sketchup_type_code?(code, name)
      end

      def sketchup_type_fallbacks
        CONTENT_TYPE_FALLBACKS.map { |code| { code: code, name: code } }
      end

      def normalize_content_type(item)
        hash = stringify_keys(item)
        {
          code: (hash['Code'] || hash['code'] || hash['type'] || hash['id']).to_s,
          name: (hash['Name'] || hash['name'] || hash['title']).to_s
        }
      end

      def download_file(url)
        response = client.download(url)
        code = response[:code]
        raise "Не удалось скачать файл (HTTP #{code})" if code < 200 || code >= 300

        data = response[:raw].to_s
        raise 'Пустой файл' if data.empty?

        filename = filename_from_headers(response[:headers]) || File.basename(URI(url).path)
        { data: data, filename: filename }
      end

      def find_skp_file(content)
        payload = content.is_a?(Hash) ? (content['payload'] || content[:payload] || content) : nil
        files = collect_files(payload)
        skp = files.find { |file| file[:name].to_s.downcase.end_with?('.skp') }
        skp || files.first
      end

      private_class_method def self.success?(response)
        body = response[:body]
        if body.is_a?(Hash)
          err = body['error']
          code = body['code'].to_i
          return false if err.to_s.strip != '' && (code >= 400 || response[:code] >= 400)
        end
        code = response[:code]
        code >= 200 && code < 300
      end

      private_class_method def self.upload_error_message(response, fields)
        sent = scalar_field_keys(fields)
        "#{api_error_message(response)} [поля без файла: #{sent.empty? ? 'нет' : sent.join(', ')}]"
      end

      private_class_method def self.api_error_message(response)
        body = response[:body]
        parts = ["HTTP #{response[:code]}"]
        if body.is_a?(Hash)
          msg = body['error'] || body['message'] || body['msg']
          parts << msg.to_s unless msg.to_s.strip.empty?
          details = body['details'] || body['errors'] || body['validation']
          unless details.nil? || details.to_s.strip.empty?
            parts << (details.is_a?(String) ? details : details.inspect)[0, 400]
          end
        elsif body.is_a?(String) && !body.strip.empty?
          parts << body.strip[0, 400]
        end
        parts.uniq.join(' — ')
      end

      private_class_method def self.enrich_field(field)
        hash = normalize_form_field(field)
        type = hash['type'].to_s
        source = hash['source'].to_s
        if %w[list multiple_list].include?(type) && !source.empty?
          hash['options'] = fetch_references(source, hash['query'])
        end
        hash
      end

      private_class_method def self.normalize_form_field(field)
        hash = stringify_keys(field)
        required = hash['required']
        required = hash['Required'] if required.nil?
        {
          'code' => (hash['code'] || hash['Code'] || hash['key'] || hash['id']).to_s,
          'name' => (hash['name'] || hash['Name'] || hash['title'] || hash['label'] || hash['code'] || hash['Code']).to_s,
          'type' => (hash['type'] || hash['Type'] || hash['field_type'] || 'text').to_s,
          'required' => required,
          'source' => (hash['source'] || hash['Source'] || hash['source_code'] || hash['reference']).to_s,
          'accept' => (hash['accept'] || hash['Accept']).to_s,
          'query' => hash['query'] || hash['Query'],
          'options' => hash['options']
        }
      end

      private_class_method def self.ensure_required_payload_fields(fields)
        codes = fields.map { |field| field['code'].to_s }
        unless codes.include?('constr_code')
          options = []
          %w[AllIsolationConstr constr construction constructions constr_code isolation_constr].each do |source|
            options = fetch_references(source)
            break unless options.empty?
          end
          fields = fields + [{
            'code' => 'constr_code',
            'name' => 'Код конструкции',
            'type' => options.empty? ? 'text' : 'list',
            'required' => true,
            'source' => 'constr',
            'accept' => '',
            'query' => nil,
            'options' => options
          }]
        end
        fields
      end

      private_class_method def self.scalar_context(context)
        return {} unless context.is_a?(Hash)

        context.each_with_object({}) do |(key, value), acc|
          next if value.nil? || value.is_a?(Hash)
          next if %w[modelObjectId objectId groupId group_id privacy_group].include?(key.to_s)

          acc[key.to_s] = value
        end
      end

      private_class_method def self.context_cache_key(context)
        context.is_a?(Hash) ? context.keys.map(&:to_s).sort.join(',') : ''
      end

      private_class_method def self.normalize_option(item)
        hash = stringify_keys(item)
        {
          code: (hash['code'] || hash['Code'] || hash['constr_code'] || hash['construction_code'] || hash['id'] || hash['value'] || hash['key']).to_s,
          name: (hash['name'] || hash['Name'] || hash['title'] || hash['label'] || hash['code'] || hash['Code']).to_s
        }
      end

      private_class_method def self.parse_query_string(query)
        return {} if query.nil? || query.to_s.strip.empty? || !query.to_s.include?('=')

        URI.decode_www_form(query.to_s.sub(/\A\?/, '')).each_with_object({}) do |(key, value), acc|
          acc[key] = value
        end
      rescue StandardError
        {}
      end

      private_class_method def self.unwrap(body)
        return body unless body.is_a?(Hash)
        return body['data'] if body.key?('data')

        body
      end

      private_class_method def self.extract_list(payload)
        return payload if payload.is_a?(Array)
        return [] unless payload.is_a?(Hash)

        %w[content items list data].each do |key|
          value = payload[key]
          return value if value.is_a?(Array)
        end
        []
      end

      private_class_method def self.extract_fields(payload)
        return payload if payload.is_a?(Array)
        return [] unless payload.is_a?(Hash)

        %w[fields Fields formFields FormFields items Items].each do |key|
          value = payload[key]
          return value if value.is_a?(Array)
        end
        inner = payload['data']
        return extract_fields(inner) if inner.is_a?(Hash) || inner.is_a?(Array)

        []
      end

      private_class_method def self.extract_filters(payload)
        return [] unless payload.is_a?(Hash)

        payload['filters'].is_a?(Array) ? payload['filters'] : []
      end

      private_class_method def self.normalize_list_item(item)
        hash = stringify_keys(item)
        {
          id: hash['id'],
          groupId: hash['group_id'] || hash['groupId'],
          name: hash['name'].to_s,
          status: hash['status'].to_s,
          statusLabel: STATUS_LABELS[hash['status'].to_s] || hash['status'].to_s,
          updatedAt: hash['updated_at'] || hash['updatedAt'],
          updatedBy: hash['updated_by'] || hash['updatedBy'],
          contentType: hash['content_type'] || hash['contentType'] || CONTENT_TYPE_CODE,
          privacyGroup: hash['privacy_group'] || hash['privacyGroup'],
          labels: hash['labels'] || []
        }
      end

      private_class_method def self.stringify_keys(obj)
        return obj unless obj.is_a?(Hash)

        obj.each_with_object({}) do |(key, value), acc|
          acc[key.to_s] = value
        end
      end

      private_class_method def self.compact_query(filters)
        query = {}
        (filters || {}).each do |key, value|
          next if value.nil? || value.to_s.empty?
          next if %w[contentType content_type].include?(key.to_s)

          query[key.to_s] = value
        end
        query
      end

      private_class_method def self.collect_files(node, acc = [])
        case node
        when Hash
          if node['download_url'] || node[:download_url]
            h = stringify_keys(node)
            acc << {
              url: h['download_url'].to_s,
              name: h['file_name'].to_s,
              contentType: h['content_type'].to_s
            }
          else
            node.each_value { |value| collect_files(value, acc) }
          end
        when Array
          node.each { |value| collect_files(value, acc) }
        end
        acc
      end

      private_class_method def self.filename_from_headers(headers)
        raw = Array(headers['content-disposition']).join(' ')
        match = raw.match(/filename\*?=(?:UTF-8''|")?([^";]+)/i)
        return CGI.unescape(match[1]) if match

        nil
      rescue StandardError
        nil
      end
    end

  end
end
