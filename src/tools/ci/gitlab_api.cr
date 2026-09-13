module H2code
  module Tools
    module Ci
      # Вариант доступа к GitLab CI: прямой REST-клиент v4. Базовый URL —
      # хост из remote (gitlab.com или self-hosted endpoint). Токен
      # опционален: публичные проекты отвечают анонимно; приватным нужен
      # personal access token (заголовок Private-Token, никогда не
      # попадает в логи/детали наблюдателя). `http_get` — точка внедрения
      # моков для тестов.
      class GitlabApi
        getter base_url : String

        def initialize(@base_url : String = "https://gitlab.com",
                       @token : String? = nil,
                       @http_get : (String -> ApiResponse)? = nil)
        end

        # Задан ли токен (влияет на подсказку при отказе в доступе).
        def token? : Bool
          return false if (t = @token).nil?
          !t.empty?
        end

        def get(path : String) : ApiResponse
          if getter = @http_get
            return getter.call(path)
          end
          uri = URI.parse("#{@base_url}/api/v4#{path}")
          resp = HTTP::Client.new(uri) do |client|
            client.connect_timeout = 10.seconds
            client.read_timeout = 15.seconds
            client.get(uri.request_target, self.class.headers(@token))
          end
          ApiResponse.new(resp.status_code, resp.body, resp.headers["Location"]?)
        rescue ex
          ApiResponse.new(0, ex.message.to_s)
        end

        def self.headers(token : String?) : HTTP::Headers
          headers = HTTP::Headers{
            "Accept"     => "application/json",
            "User-Agent" => "h2code",
          }
          headers["Private-Token"] = token if token && !token.empty?
          headers
        end
      end
    end
  end
end
