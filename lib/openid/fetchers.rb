require 'net/http'
require 'openid'
require 'openid/util'

begin
  require 'net/https'
rescue LoadError
  OpenID::Util.log('WARNING: no SSL support found.  Will not be able ' +
                   'to fetch HTTPS URLs!')
  require 'net/http'
end

module Net
  class HTTP
    def post_connection_check(hostname)
      check_common_name = true
      cert = @socket.io.peer_cert
      cert.extensions.each { |ext|
        next if ext.oid != "subjectAltName"
        ext.value.split(/,\s+/).each{ |general_name|
          if /\ADNS:(.*)/ =~ general_name
            check_common_name = false
            reg = Regexp.escape($1).gsub(/\\\*/, "[^.]+")
            return true if /\A#{reg}\z/i =~ hostname
          elsif /\AIP Address:(.*)/ =~ general_name
            check_common_name = false
            return true if $1 == hostname
          end
        }
      }
      if check_common_name
        cert.subject.to_a.each{ |oid, value|
          if oid == "CN"
            reg = Regexp.escape(value).gsub(/\\\*/, "[^.]+")
            return true if /\A#{reg}\z/i =~ hostname
          end
        }
      end
      raise OpenSSL::SSL::SSLError, "hostname does not match"
    end
  end
end

module OpenID
  # Our HTTPResponse class extends Net::HTTPResponse with an additional
  # method, final_url.
  class HTTPResponse
    attr_accessor :final_url

    attr_accessor :_response

    def self._from_net_response(response, final_url, headers=nil)
      me = self.new
      me._response = response
      me.initialize_http_header headers
      me.final_url = final_url
      return me
    end

    def self._from_raw_data(status, body="", headers={}, final_url=nil)
      resp = Net::HTTPResponse.new('1.1', status, 'NONE')
      me = self._from_net_response(resp, final_url, headers)
      me.body = body
      return me
    end

    def method_missing(method, *args)
      @_response.send(method, *args)
    end

    def body=(s)
      @_response.instance_variable_set('@body', s)
      # XXX Hack to work around ruby's HTTP library behavior.  @body
      # is only returned if it has been read from the response
      # object's socket, but since we're not using a socket in this
      # case, we need to set the @read flag to true to avoid a bug in
      # Net::HTTPResponse.stream_check when @socket is nil.
      @_response.instance_variable_set('@read', true)
    end
  end

  class FetchingError < StandardError
  end

  class HTTPRedirectLimitReached < FetchingError
  end

  class SSLFetchingError < FetchingError
  end

  @fetcher = nil

  def self.fetch(url, body=nil, headers=nil,
                 redirect_limit=StandardFetcher::REDIRECT_LIMIT)
    return fetcher.fetch(url, body, headers, redirect_limit)
  end

  def self.fetcher
    if @fetcher.nil?
      @fetcher = StandardFetcher.new
    end

    return @fetcher
  end

  def self.fetcher=(fetcher)
    @fetcher = fetcher
  end

  class StandardFetcher

    # FIXME: Use an OpenID::VERSION constant here.
    USER_AGENT = "ruby-openid/#{VERSION} (#{PLATFORM})"

    REDIRECT_LIMIT = 5

    attr_accessor :ca_file

    def initialize
      @ca_file = nil
    end

    def supports_ssl?(conn)
      return conn.respond_to?(:use_ssl=)
    end

    def make_http(uri)
      Net::HTTP.new(uri.host, uri.port)
    end

    def set_verified(conn, verify)
      if verify
        conn.verify_mode = OpenSSL::SSL::VERIFY_PEER
      else
        conn.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
    end

    def make_connection(uri)
      conn = make_http(uri)

      if !conn.is_a?(Net::HTTP)
        raise RuntimeError, sprintf("Expected Net::HTTP object from make_http; got %s",
                                    conn.class)
      end

      if uri.scheme == 'https'
        if supports_ssl?(conn)

          conn.use_ssl = true

          if @ca_file
            set_verified(conn, true)
            conn.ca_file = @ca_file
          else
            Util.log("WARNING: making https request to #{uri} without verifying " +
                     "server certificate; no CA path was specified.")
            set_verified(conn, false)
          end
        else
          raise RuntimeError, "SSL support not found; cannot fetch #{uri}"
        end
      end

      return conn
    end

    def fetch(url, body=nil, headers=nil, redirect_limit=REDIRECT_LIMIT)
      unparsed_url = url.dup
      url = URI::parse(url)

      headers ||= {}
      headers['User-agent'] ||= USER_AGENT

      conn = make_connection(url)
      response = nil

      begin
        response = conn.start {
          # Check the certificate against the URL's hostname
          if supports_ssl?(conn) and conn.use_ssl?
            conn.post_connection_check(url.host)
          end

          if body.nil?
            conn.request_get(url.request_uri, headers)
          else
            headers["Content-type"] ||= "application/x-www-form-urlencoded"
            conn.request_post(url.request_uri, body, headers)
          end
        }
      rescue OpenSSL::SSL::SSLError => why
        raise SSLFetchingError, "Error connecting to SSL URL #{url}: #{why}"
      end

      case response
      when Net::HTTPRedirection
        if redirect_limit <= 0
          raise HTTPRedirectLimitReached.new(
            "Too many redirects, not fetching #{response['location']}")
        end
        return fetch(response['location'], body, headers, redirect_limit - 1)
      else
        return HTTPResponse._from_net_response(response, unparsed_url)
      end
    end
  end
end
