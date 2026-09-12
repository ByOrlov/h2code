module H2code
  module Tools
    module Ci
      # Адаптер GitHub Actions к Ci::Port. Внутри держит варианты доступа:
      # GithubApi (REST, когда есть токен и известен репозиторий) и
      # GithubCli (gh, фолбэк без токена). Выбор доступа — на стороне
      # адаптера: api используется, когда он передан.
      class GithubClient < Port
        def initialize(@repo : RepoInfo?, @api : GithubApi?, @cli : GithubCli)
        end

        # Прогоны Actions для коммита: REST `/actions/runs?head_sha=…`
        # (per_page=100: выдача newest-first, и служебные Dependabot-прогоны
        # не должны вытеснить реальные прогоны коммита с первой страницы до
        # фильтрации) либо `gh run list -c …`.
        def runs(sha : String) : Port::Check
          if (repo = @repo) && (api = @api)
            runs_via_api(repo, api, sha)
          else
            runs_via_cli(@cli, sha)
          end
        end

        # Лог упавшего прогона: REST run-logs отвечает 302 на signed URL с
        # zip текстовых логов шагов; gh-путь — `gh run view --log-failed`.
        # Недоступность лога возвращается с причиной (Port::Log#error), а
        # не молча.
        def failure_log(check : Port::Check) : Port::Log
          failed = check.runs.find(&.state.failed?)
          return Port::Log.new if failed.nil?
          if (repo = @repo) && (api = @api)
            api_failure_log(repo, api, failed)
          else
            failed.id.empty? ? Port::Log.new : cli_failure_log(@cli, failed)
          end
        end

        # Нормализация строк Actions API / `gh run list` к Port::Run.
        # Строки с event=dynamic (служебные Dependabot-прогоны,
        # прицепленные к голове дефолтной ветки) — не сборки коммита и
        # отбрасываются: посчитанные как пройденные, они фабрикуют
        # зелёный вердикт.
        def self.map_runs(rows : Array(JSON::Any)) : Array(Port::Run)
          rows.reject { |row| row["event"]?.try(&.to_s) == "dynamic" }.map do |row|
            status = row["status"]?.try(&.to_s) || ""
            conclusion = row["conclusion"]?.try(&.to_s) || ""
            state = Port::RunState::InProgress
            if status == "completed"
              state = BAD_CONCLUSIONS.includes?(conclusion) ? Port::RunState::Failed : Port::RunState::Passed
            end
            Port::Run.new(
              id: row["id"]?.try(&.to_s) || row["databaseId"]?.try(&.to_s) || "",
              name: row["name"]?.try(&.to_s) || "run",
              state: state,
              failure_reason: state.failed? ? conclusion : "",
            )
          end
        end

        private def runs_via_api(repo : RepoInfo, api : GithubApi, sha : String) : Port::Check
          res = api.get("/repos/#{repo.path}/actions/runs?head_sha=#{sha}&per_page=100")
          unless res.status_code == 200
            return transient("GitHub API HTTP #{res.status_code}: #{Ci.excerpt(res.body, DETAIL_EXCERPT_BYTES)}")
          end
          begin
            rows = JSON.parse(res.body)["workflow_runs"].as_a
          rescue JSON::ParseException | KeyError | TypeCastError
            return transient("unexpected GitHub API output: #{Ci.excerpt(res.body, DETAIL_EXCERPT_BYTES)}")
          end
          check_runs(GithubClient.map_runs(rows))
        end

        private def runs_via_cli(cli : GithubCli, sha : String) : Port::Check
          res = cli.run_list(sha)
          unless res.exit_code == 0
            return transient("gh failed (exit #{res.exit_code}): #{Ci.excerpt(res.output, DETAIL_EXCERPT_BYTES)}")
          end
          begin
            rows = JSON.parse(res.output).as_a
          rescue JSON::ParseException | TypeCastError
            # stderr gh подмешивается в stdout — вывод может не быть JSON.
            return transient("unexpected gh output: #{Ci.excerpt(res.output, DETAIL_EXCERPT_BYTES)}")
          end
          check_runs(GithubClient.map_runs(rows))
        end

        private def check_runs(runs : Array(Port::Run)) : Port::Check
          status, detail = Port.aggregate(runs, "no runs reported yet", "run(s)")
          Port::Check.new(status, detail, runs)
        end

        private def api_failure_log(repo : RepoInfo, api : GithubApi, failed : Port::Run) : Port::Log
          res = api.get("/repos/#{repo.path}/actions/runs/#{failed.id}/logs")
          if res.status_code == 302 && (loc = res.location)
            res = api.get(loc)
          end
          unless res.status_code == 200
            return Port::Log.new(error: "GitHub API HTTP #{res.status_code}: #{Ci.excerpt(res.body, DETAIL_EXCERPT_BYTES)}")
          end
          text = Ci.extract_zip_text(res.body)
          text.empty? ? Port::Log.new : Port::Log.new(text: text)
        rescue
          Port::Log.new
        end

        # gh-путь: лог упавших шагов; при пустом id прогона лога нет.
        private def cli_failure_log(cli : GithubCli, failed : Port::Run) : Port::Log
          res = cli.log_failed(failed.id)
          unless res.exit_code == 0
            return Port::Log.new(error: "gh failed (exit #{res.exit_code}): #{Ci.excerpt(res.output, DETAIL_EXCERPT_BYTES)}")
          end
          res.output.empty? ? Port::Log.new : Port::Log.new(text: res.output)
        end

        private def transient(detail : String) : Port::Check
          Port::Check.new(Status::Error, detail)
        end
      end
    end
  end
end
