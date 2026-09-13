module H2code
  module Tools
    module Ci
      # Вариант доступа к GitHub Actions через gh CLI — работает без
      # токена в конфиге h2code, если пользователь вошёл в gh
      # интерактивно. Обёртка над подстановкой команд; выполнение идёт
      # через внедряемый runner (боевой — LiveCiService#runner, тесты
      # подставляют фейк).
      class GithubCli
        def initialize(@runner : (String, String) -> CommandResult, @cwd : String)
        end

        # JSON-строки прогонов коммита (`gh run list -c`). `event`
        # запрашивается, чтобы агрегация могла отбросить служебные
        # Dependabot-прогоны; `--limit 100` не даёт вытеснить реальные
        # прогоны из выдачи newest-first. Сырой вывод — разбор в клиенте.
        def run_list(sha : String) : CommandResult
          @runner.call(
            "gh run list -c #{sha} --json databaseId,name,status,conclusion,event --limit 100",
            @cwd)
        end

        # Лог упавших шагов прогона (сырой результат команды — решение об
        # ошибке принимает клиент).
        def log_failed(run_id : String) : CommandResult
          @runner.call("gh run view #{run_id} --log-failed", @cwd)
        end
      end
    end
  end
end
