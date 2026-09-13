module H2code
  module Tools
    module Ci
      # Вариант доступа к GitHub Actions: прямой REST-клиент — «собственный
      # Crystal-аналог» `gh run list` / `gh run view --log-failed`. Токен
      # идёт только в заголовок Authorization и никогда не попадает в
      # логи/детали наблюдателя. `http_get` — опциональная точка внедрения
      # для тестов (моки ответов без сети); без него — реальные запросы к
      # api.github.com с прозрачным следованием за 3xx.
      class GithubApi
        API_BASE = "https://api.github.com"
        # Redirect hops followed per request — renamed repositories answer
        # 301 with the canonical `repositories/{id}` path, run logs answer
        # 302 with a signed URL.
        MAX_REDIRECTS = 3

        def initialize(@token : String? = nil, @http_get : (String -> ApiResponse)? = nil)
        end

        def get(path : String) : ApiResponse
          if getter = @http_get
            return getter.call(path)
          end
          url = path.starts_with?("http") ? path : "#{API_BASE}#{path}"
          MAX_REDIRECTS.times do
            uri = URI.parse(url)
            resp = HTTP::Client.new(uri) do |client|
              client.connect_timeout = 10.seconds
              client.read_timeout = 15.seconds
              client.get(uri.request_target, self.class.headers(@token))
            end
            target = self.class.redirect_target(resp)
            if target
              url = target.starts_with?("http") ? target : "#{uri.scheme}://#{uri.host}#{target}"
              next
            end
            return ApiResponse.new(resp.status_code, resp.body, resp.headers["Location"]?)
          end
          ApiResponse.new(0, "too many redirects: #{url}")
        rescue ex
          ApiResponse.new(0, ex.message.to_s)
        end

        # Redirect target of a 3xx GitHub API response: the Location
        # header, or the `url` field of the JSON body (GitHub's
        # moved-repository notices carry the canonical URL in the body).
        # Nil for non-redirect responses without a usable target.
        def self.redirect_target(resp : HTTP::Client::Response) : String?
          return nil unless resp.status.redirection?
          location = resp.headers["Location"]?
          return location if location && !location.empty?
          resp.body.match(/"url":\s*"(https?:[^"]+)"/).try(&.[1].gsub("\\/", "/"))
        end

        def self.headers(token : String?) : HTTP::Headers
          headers = HTTP::Headers{
            "Accept"               => "application/vnd.github+json",
            "X-GitHub-Api-Version" => "2022-11-28",
            "User-Agent"           => "h2code",
          }
          headers["Authorization"] = "Bearer #{token}" if token && !token.empty?
          headers
        end
      end
    end
  end
end
