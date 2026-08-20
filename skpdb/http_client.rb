require 'net/http'
require 'uri'
require 'json'
require 'openssl'
require 'securerandom'
require 'cgi'
require 'stringio'

module Constrtodo
  module SkpDb

    # Синхронный HTTP-клиент с cookie-сессией и CSRF, как во фронтенде ConstrTodoWeb.
    class HttpClient
      attr_reader :cookies

      def initialize(base_url)
        @base_url = base_url.to_s.sub(%r{/\z}, '')
        @cookies = {}
        @open_timeout = 12
        @read_timeout = 120
      end

      def cookies=(hash)
        @cookies = {}
        (hash || {}).each do |key, value|
          name = key.to_s
          val = value.to_s
          @cookies[name] = val unless name.empty?
        end
      end

      def csrf_token
        raw = @cookies['csrf_token'] || @cookies['CSRF-TOKEN'] || @cookies['XSRF-TOKEN'] ||
              @cookies['_csrf'] || @cookies['csrf']
        percent_decode(raw)
      end

      def get(path, query: nil, accept: 'application/json')
        request(:get, path, query: query, accept: accept)
      end

      def post_json(path, body)
        request(:post, path, json: body)
      end

      def post_form(path, fields)
        request(:post, path, form: fields)
      end

      def put_form(path, fields)
        request(:put, path, form: fields)
      end

      def download(url_or_path)
        uri = absolute_uri(url_or_path)
        request_uri(uri, :get, accept: '*/*')
      end

      private

      def request(method, path, query: nil, json: nil, form: nil, accept: 'application/json')
        uri = join_uri(path, query)
        request_uri(uri, method, json: json, form: form, accept: accept)
      end

      def request_uri(uri, method, json: nil, form: nil, accept: 'application/json')
        perform_request(uri, method, json: json, form: form, accept: accept, verify: true)
      rescue OpenSSL::SSL::SSLError
        retry_insecure(uri, method, json: json, form: form, accept: accept)
      end

      def retry_insecure(uri, method, json: nil, form: nil, accept: 'application/json')
        # SketchUp Ruby часто без CA-сертификатов — повтор только после сбоя VERIFY_PEER.
        perform_request(uri, method, json: json, form: form, accept: accept, verify: false)
      end

      def perform_request(uri, method, json:, form:, accept:, verify:)
        http = new_http(uri, verify: verify)
        req = build_request(uri, method, json: json, form: form, accept: accept)
        apply_headers!(req)
        response = http.request(req)
        store_cookies!(response)
        body = decode_body(response)
        {
          code: response.code.to_i,
          headers: response.to_hash,
          body: body,
          raw: response.body
        }
      end

      def new_http(uri, verify:)
        proxy = proxy_uri
        http = if proxy
                 Net::HTTP.new(uri.host, uri.port, proxy.host, proxy.port, proxy.user, proxy.password)
               else
                 Net::HTTP.new(uri.host, uri.port)
               end
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        if uri.scheme == 'https'
          http.use_ssl = true
          http.verify_mode = verify ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
        end
        http
      end

      def proxy_uri
        raw = ENV['HTTPS_PROXY'] || ENV['https_proxy'] || ENV['HTTP_PROXY'] || ENV['http_proxy']
        return nil if raw.to_s.strip.empty?

        uri = URI(raw)
        return nil if uri.host.to_s.empty?

        uri
      rescue StandardError
        nil
      end

      def build_request(uri, method, json:, form:, accept:)
        request_class = case method
                        when :post then Net::HTTP::Post
                        when :put then Net::HTTP::Put
                        when :delete then Net::HTTP::Delete
                        else Net::HTTP::Get
                        end
        path = uri.request_uri
        path = '/' if path.nil? || path.empty?
        req = request_class.new(path)
        req['Accept'] = accept
        req['Accept-Encoding'] = 'identity'
        req['User-Agent'] = "ConstrTodo-SKP/#{VERSION} SketchUp"

        if json
          req['Content-Type'] = 'application/json; charset=utf-8'
          req.body = JSON.generate(json)
        elsif form
          boundary = "----WebKitFormBoundary#{SecureRandom.hex(16)}"
          body = encode_multipart(form, boundary)
          req['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
          req['Content-Length'] = body.bytesize.to_s
          req.body = body
        end
        req
      end

      def apply_headers!(req)
        unless @cookies.empty?
          req['Cookie'] = @cookies.map { |key, value|
            "#{key}=#{raw_cookie_value(value)}"
          }.join('; ')
        end

        token = csrf_token
        req['X-CSRF-Token'] = token unless token.empty?
      end

      def store_cookies!(response)
        fields = response.get_fields('set-cookie')
        return if fields.nil?

        fields.each do |raw|
          pair = raw.to_s.split(';', 2).first
          next if pair.nil? || !pair.include?('=')

          name, value = pair.split('=', 2)
          name = name.to_s.strip
          next if name.empty?

          @cookies[name] = raw_cookie_value(value)
        end
      end

      def raw_cookie_value(value)
        text = value.to_s.strip
        if text.length >= 2 && text.start_with?('"') && text.end_with?('"')
          text = text[1..-2]
        end
        text
      end

      def percent_decode(value)
        text = raw_cookie_value(value)
        return '' if text.empty?

        text.gsub(/%([0-9A-Fa-f]{2})/) { [$1.hex].pack('C') }
      end

      def decode_body(response)
        raw = response.body.to_s
        content_type = response['content-type'].to_s
        return raw if raw.empty?
        return raw unless content_type.include?('json') || raw.lstrip.start_with?('{', '[')

        JSON.parse(raw)
      rescue JSON::ParserError
        raw
      end

      def encode_multipart(fields, boundary)
        io = StringIO.new
        io.set_encoding(Encoding::BINARY)
        ordered = fields.to_a
        scalars, files = ordered.partition { |_name, value| !file_part?(value) }
        (scalars + files).each do |name, value|
          next if value.nil?

          if file_part?(value)
            filename = (value[:filename] || value['filename']).to_s
            filename = 'model.skp' if filename.empty?
            data = value[:data] || value['data']
            data = binary_string(data)
            mime = (value[:mime] || value['mime']).to_s
            mime = 'application/octet-stream' if mime.empty?
            write_bin(io, "--#{boundary}\r\n")
            write_bin(io, %(Content-Disposition: form-data; name="#{name}"; filename="#{sanitize_filename(filename)}"\r\n))
            write_bin(io, "Content-Type: #{mime}\r\n\r\n")
            io.write(data)
            write_bin(io, "\r\n")
          else
            Array(value).each do |item|
              write_bin(io, "--#{boundary}\r\n")
              write_bin(io, %(Content-Disposition: form-data; name="#{name}"\r\n\r\n))
              write_bin(io, item.to_s)
              write_bin(io, "\r\n")
            end
          end
        end
        write_bin(io, "--#{boundary}--\r\n")
        io.string
      end

      def write_bin(io, text)
        io.write(binary_string(text))
      end

      def binary_string(value)
        str = value.nil? ? ''.dup : value.to_s.dup
        str.force_encoding(Encoding::BINARY)
      end

      def file_part?(value)
        value.is_a?(Hash) && (value.key?(:filename) || value.key?(:data) || value.key?('filename'))
      end

      def sanitize_filename(name)
        File.basename(name.to_s).gsub(/[^\w.\-А-Яа-яЁё ]+/, '_')
      end

      def join_uri(path, query)
        path = path.to_s
        uri = if path.start_with?('http://', 'https://')
                URI(path)
              else
                URI("#{@base_url}/#{path.sub(%r{\A/}, '')}")
              end
        if query && !query.empty?
          params = URI.decode_www_form(uri.query.to_s)
          query.each do |key, value|
            next if value.nil?

            if value.is_a?(Array)
              value.each { |item| params << [key.to_s, item.to_s] }
            else
              params << [key.to_s, value.to_s]
            end
          end
          uri.query = URI.encode_www_form(params)
        end
        uri
      end

      def absolute_uri(url_or_path)
        value = url_or_path.to_s
        return URI(value) if value.start_with?('http://', 'https://')

        origin = URI(@base_url)
        origin = URI("#{origin.scheme}://#{origin.host}#{":#{origin.port}" unless [80, 443].include?(origin.port)}")
        if value.start_with?('/')
          URI("#{origin}#{value}")
        else
          join_uri(value, nil)
        end
      end
    end

  end
end
