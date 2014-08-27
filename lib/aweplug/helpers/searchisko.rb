require 'faraday'
require 'faraday_middleware' 
require 'aweplug/cache/yaml_file_cache'
require 'logger'
require 'json'
require 'uri'

# WARNING: monkey patching faraday
# TODO: See if we can the new refinements to work
module Faraday
  module Utils
    def build_nested_query(value, prefix = nil)
      case value
      when Array
        value.map { |v| build_nested_query(v, "#{prefix}") }.join("&")
      when Hash
        value.map { |k, v|
          build_nested_query(v, prefix ? "#{prefix}%5B#{escape(k)}%5D" : escape(k))
        }.join("&")
      when NilClass
        prefix
      else
        raise ArgumentError, "value must be a Hash" if prefix.nil?
        "#{prefix}=#{escape(value)}"
      end
    end
  end
end

module Aweplug
  module Helpers
    # Public: A helper class for using Searchisko.
    class Searchisko 
      # Public: Initialization of the object, keeps a Faraday connection cached.
      #
      # opts - symbol keyed hash. Current keys used:
      #        :base_url - base url for the searchisko instance
      #        :authenticate - boolean flag for authentication
      #        :searchisko_username - Username to use for auth
      #        :searchisko_password - Password to use for auth
      #        :logger - Boolean to log responses or an instance of Logger to use
      #        :raise_error - Boolean flag if 404 and 500 should raise exceptions
      #        :adapter - faraday adapter to use, defaults to :net_http
      #        :cache - Instance of a cache to use, required.
      #
      # Returns a new instance of Searchisko.
      def initialize opts={} 
        # We want to fail fast on missing or empty required options
        unless ((opts.key?(:searchisko_username) && opts.key?(:searchisko_password)) || (opts[:searchisko_username].empty? || opts[:searchisko_password].empty?))
          raise 'Missing searchisko credentials'
        end
        @faraday = Faraday.new(:url => opts[:base_url]) do |builder|
          builder.request :basic_auth, opts[:searchisko_username], opts[:searchisko_password]
          if (opts[:logger]) 
            if (opts[:logger].is_a?(::Logger))
              builder.response :logger, @logger = opts[:logger]
            else 
              builder.response :logger, @logger = ::Logger.new('_tmp/faraday.log', 'daily')
            end
          end
          builder.request :url_encoded
          builder.request :retry
          builder.response :raise_error if opts[:raise_error]
          builder.use FaradayMiddleware::Caching, opts[:cache], {}
          #builder.response :json, :content_type => /\bjson$/
          builder.adapter opts[:adapter] || :net_http
        end
        @cache = opts[:cache]
        @searchisko_warnings = opts[:searchisko_warnings] if opts.has_key? :searchisko_warnings
      end

      # Public: Performs a GET normalization against the Searchisko API
      #
      # normalization - The id of the normalization to use
      # id - The id to normalize
      def normalize normalization, id
        #key = "normalization-#{normalization}-#{id}"
        #json = @cache.read(key)
        #if json.nil?
          response = get "/normalization/#{normalization}/#{id}"
          if response.success?
            json = JSON.load(response.body)
            #@cache.write(key, json)
          end
        #end
        yield json
      end

      # Public: Performs a GET search against the Searchisko instance using 
      # provided parameters.
      #
      # params - Hash of parameters to use as query string. See
      #          http://docs.jbossorg.apiary.io/#searchapi for more information
      #          about parameters and how they affect the search.
      #
      # Example
      #
      #   searchisko.search {:query => 'Search query'}
      #   # => {...}
      #
      # Returns the String result of the search.
      def search params = {}
        get '/search', params
      end

      # Public: Makes an HTTP GET to host/v1/rest/#{path} and returns the 
      # result from the Faraday request.
      #
      # path   - String containing the rest of the path.
      # params - Hash containing query string parameters.
      #
      # Example
      #   
      #   searchisko.get 'feed', {:query => 'Search Query'}
      #   # => Faraday Response Object
      #
      # Returns the Faraday Response for the request.
      def get path, params = {}
        response = @faraday.get URI.escape("/v1/rest/" + path), params
        unless response.success?
          $LOG.warn "Error making searchisko request to #{path}. Status: #{response.status}. Params: #{params}" if $LOG.warn?
        end
        response
      end

      # Public: Posts content to Searchisko.
      #
      # content_type - String of the Searchisko sys_content_type for the content 
      #                being posted.
      # content_id   - String of the Searchisko sys_content_id for the content.
      # params       - Hash containing the content to push.
      #
      # Examples
      #
      #   searchisko.push_content 'jbossdeveloper_bom', id, content_hash
      #   # => Faraday Response
      #
      # Returns a Faraday Response from the POST.
      def push_content content_type, content_id, params = {}
        post "/content/#{content_type}/#{content_id}", params
      end

      # Public: Perform an HTTP POST to Searchisko.
      #
      # path   - String containing the rest of the path.
      # params - Hash containing the POST body.
      #
      # Examples
      #
      #   searchisko.post "rating/#{searchisko_document_id}", {rating: 3}
      #   # => Faraday Response
      def post path, params = {}
        resp = @faraday.post do |req|
          req.url "/v1/rest/" + path
          req.headers['Content-Type'] = 'application/json'
          req.body = params
          if @logger
            @logger.debug "request body: #{req.body}"
          end
        end
        body = JSON.parse(resp.body)
        if @logger && (!resp.status.between?(200, 300) || body.has_key?("warnings"))
          @logger.debug "response body: #{resp.body}"
        end
        if $LOG.warn?
          if !resp.success?
            $LOG.warn "Error making searchisko request to '#{path}'. Status: #{resp.status}. 
                       Params: #{params}. Response body: #{resp.body}"
          elsif body.has_key? "warnings"
            unless @searchisko_warnings.nil?
              File.open(@searchisko_warnings, File::RDWR|File::CREAT, 0644) do |file|
                file.flock(File::LOCK_EX)
                if file.size > 0
                  content = JSON.load(file)
                else
                  content = []
                end
                content << {:path => path, :body => body, :headers => resp.headers, :status => resp.status}
                file.rewind
                file.write(content.to_json)
              end
            else
              $LOG.warn "Searchisko content POST to '#{path}' succeeded with warnings: #{body["warnings"]}"
            end
          end
        end
      end
    end
  end
end

