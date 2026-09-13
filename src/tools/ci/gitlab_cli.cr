module H2code
  module Tools
    module Ci
      # Вариант доступа к GitLab CI через glab CLI (`glab api` —
      # аутентифицированный passthrough к тем же v4-эндпоинтам; его логин
      # покрывает приватные проекты без токена в конфиге h2code).
      # Явный `-X GET` важен: с одним --hostname glab меняет метод по
      # умолчанию на POST. Выполнение — через внедряемый runner.
      class GitlabCli
        def initialize(@runner : (String, String) -> CommandResult, @cwd : String, @host : String)
        end

        # GET одного v4-эндпоинта, путь — с ведущим `/`.
        def get(path : String) : CommandResult
          @runner.call(self.class.api_command(@host, path), @cwd)
        end

        # Shell-инвокация `glab api` для одного v4-эндпоинта. Путь
        # берётся в одинарные кавычки (в нём ?/&/%); его байты — из
        # percent-закодированного project ref и hex/числовых id, никогда
        # кавычка.
        def self.api_command(host : String, path : String) : String
          "glab api --hostname #{host} -X GET '#{path.lchop('/')}'"
        end
      end
    end
  end
end
