module H2code
  module Tools
    module Ci
      # Адаптер GitLab CI к Ci::Port. Варианты доступа: GitlabApi (REST,
      # токен опционален — публичные проекты отвечают анонимно) и
      # GitlabCli (glab api, покрывает приватные проекты своим логином).
      # При отказе в доступе по REST (401/403/404 — GitLab скрывает
      # приватные проекты за 404) запрос повторяется через glab, если тот
      # доступен; без glab отказ перманентный — ретраи внутри сессии его
      # не изменят.
      class GitlabClient < Port
        def initialize(@repo : RepoInfo, @api : GitlabApi, @cli : GitlabCli,
                       @glab_ready : -> Bool)
        end

        # Пайплайны коммита: `GET /projects/<ref>/pipelines?sha=…`.
        # Серверный ?sha= фильтр некоторыми инстансами применяется
        # свободно, поэтому строки перепроверяются по полю sha на
        # клиенте (см. map_pipelines): вердикт никогда не берётся из
        # пайплайна чужого коммита.
        def runs(sha : String) : Port::Check
          res = @api.get("/projects/#{@repo.gitlab_project_ref}/pipelines?sha=#{sha}&per_page=20")
          if {401, 403, 404}.includes?(res.status_code) && @glab_ready.call
            runs_via_glab(sha)
          else
            check_from_rest(res, sha)
          end
        end

        # Лог упавшего пайплайна: первый жёстко упавший job (allow_failure
        # не роняет пайплайн) → его trace (plain text). Тот же выбор
        # доступа, что и в runs: REST, при отказе в доступе — glab.
        # Недоступность лога (например, fine-grained токен без права
        # Job: Read на trace-эндпоинт) возвращается с причиной — молчаливое
        # отсутствие лога не даёт понять, чинить токен или сборку.
        def failure_log(check : Port::Check) : Port::Log
          failed = check.runs.find(&.state.failed?)
          return Port::Log.new if failed.nil? || failed.project_id.empty?
          jobs = fetch("/projects/#{failed.project_id}/pipelines/#{failed.id}/jobs?per_page=50")
          unless jobs.ok
            return Port::Log.new(error: "job list unavailable — #{jobs.error}")
          end
          begin
            rows = JSON.parse(jobs.body).as_a
          rescue JSON::ParseException | TypeCastError
            return Port::Log.new
          end
          job = rows.find do |j|
            j["status"]?.try(&.to_s) == "failed" && j["allow_failure"]?.try(&.as_bool?) != true
          end
          job_id = job.try { |j| j["id"]?.try(&.to_s) }
          return Port::Log.new if job_id.nil?
          trace = fetch("/projects/#{failed.project_id}/jobs/#{job_id}/trace")
          if trace.ok
            trace.body.empty? ? Port::Log.new : Port::Log.new(text: trace.body)
          else
            Port::Log.new(error: "job log unavailable — #{trace.error}")
          end
        end

        # Нормализация строк пайплайнов к Port::Run. Строки с чужим sha
        # отбрасываются (строки без sha — очень старые инстансы —
        # остаются: неразрешимый ввод деградирует до серверного фильтра).
        # web_url берётся из строки, иначе строится от `web_base`
        # ("<базовый URL>/<путь проекта>"); пустой web_base (агрегация
        # без репозитория) даёт пустую ссылку.
        def self.map_pipelines(rows : Array(JSON::Any), sha : String?, web_base : String) : Array(Port::Run)
          runs = [] of Port::Run
          rows.each do |row|
            row_sha = row["sha"]?.try(&.to_s)
            next if sha && row_sha && row_sha != sha
            status = row["status"]?.try(&.to_s) || ""
            state = if GITLAB_BAD_STATUSES.includes?(status)
                      Port::RunState::Failed
                    elsif GITLAB_GOOD_STATUSES.includes?(status)
                      Port::RunState::Passed
                    else
                      Port::RunState::InProgress
                    end
            id = row["id"]?.try(&.to_s) || "?"
            fallback_url = web_base.empty? ? "" : "#{web_base}/-/pipelines/#{id}"
            runs << Port::Run.new(
              id: id,
              name: "pipeline ##{id}",
              state: state,
              failure_reason: state.failed? ? status : "",
              web_url: row["web_url"]?.try(&.to_s).presence || fallback_url,
              sha: row_sha,
              project_id: row["project_id"]?.try(&.to_s) || "",
            )
          end
          runs
        end

        private def check_from_rest(res : ApiResponse, sha : String) : Port::Check
          case res.status_code
          when 200
            begin
              rows = JSON.parse(res.body).as_a
            rescue JSON::ParseException | TypeCastError
              return transient("unexpected GitLab API output: #{Ci.excerpt(res.body, DETAIL_EXCERPT_BYTES)}")
            end
            check_pipelines(rows, sha)
          when 401, 403, 404
            # Отказ не разрешится ретраями внутри сессии: 404 прячет
            # приватный проект, 401/403 отвергают анонима/плохой токен.
            Port::Check.new(Status::Error,
              "GitLab API HTTP #{res.status_code}: #{access_denied_hint}",
              permanent_error: true)
          else
            transient("GitLab API HTTP #{res.status_code}: #{Ci.excerpt(res.body, DETAIL_EXCERPT_BYTES)}")
          end
        end

        private def runs_via_glab(sha : String) : Port::Check
          res = @cli.get("/projects/#{@repo.gitlab_project_ref}/pipelines?sha=#{sha}&per_page=20")
          unless res.exit_code == 0
            return transient("glab failed (exit #{res.exit_code}): #{Ci.excerpt(res.output, DETAIL_EXCERPT_BYTES)}")
          end
          begin
            rows = JSON.parse(res.output).as_a
          rescue JSON::ParseException | TypeCastError
            return transient("unexpected glab output: #{Ci.excerpt(res.output, DETAIL_EXCERPT_BYTES)}")
          end
          check_pipelines(rows, sha)
        end

        private def check_pipelines(rows : Array(JSON::Any), sha : String?) : Port::Check
          web_base = "#{@api.base_url}/#{@repo.path}"
          runs = GitlabClient.map_pipelines(rows, sha, web_base)
          status, detail = Port.aggregate(runs, "no pipelines reported yet", "pipeline(s)")
          Port::Check.new(status, detail, runs)
        end

        # GET одного v4-эндпоинта: сперва REST; при отказе в доступе
        # (401/403/404) и доступном glab — повтор через glab api. Ошибка
        # несёт код и выдержку тела ответа GitLab (в ней — причина, как
        # insufficient_granular_scope у fine-grained токена).
        private record Fetched, ok : Bool, body : String = "", error : String = ""

        private def fetch(path : String) : Fetched
          res = @api.get(path)
          return Fetched.new(true, res.body) if res.status_code == 200
          if {401, 403, 404}.includes?(res.status_code) && @glab_ready.call
            cli_res = @cli.get(path)
            return Fetched.new(true, cli_res.output) if cli_res.exit_code == 0
          end
          Fetched.new(false,
            error: "GitLab API HTTP #{res.status_code}: #{Ci.excerpt(res.body, DETAIL_EXCERPT_BYTES)}")
        end

        private def access_denied_hint : String
          if @api.token?
            "the configured GitLab token was rejected — check gitlab.token / GITLAB_TOKEN and its access to this project (a fine-grained token additionally needs the CI/CD 'Pipeline: Read' permission)"
          else
            "no GitLab token is configured and anonymous access was denied (GitLab answers 404 for private projects) — set gitlab.token / GITLAB_TOKEN or log in with `glab auth login`"
          end
        end

        private def transient(detail : String) : Port::Check
          Port::Check.new(Status::Error, detail)
        end
      end
    end
  end
end
