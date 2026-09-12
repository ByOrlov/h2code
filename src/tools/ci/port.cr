module H2code
  module Tools
    module Ci
      # Единый порт доступа к CI провайдера (hexagonal port): проверка
      # статуса коммита и запрос логов его прогона CI — универсальное
      # поведение, общее для всех провайдеров. Всё остальное (какие
      # эндпоинты звать, как парсить ответы, REST или CLI) — внутреннее
      # дело адаптеров:
      #
      #   GithubClient — адаптер GitHub Actions (варианты доступа:
      #                  GithubApi REST / GithubCli через gh)
      #   GitlabClient — адаптер GitLab CI (GitlabApi REST / GitlabCli
      #                  через glab)
      #
      # Какой адаптер использовать решает вызывающая сторона по своей
      # логике определения провайдера (см. LiveCiService#poll_once).
      abstract class Port
        # Нормализованное состояние одного прогона CI.
        enum RunState
          InProgress
          Passed
          Failed

          def terminal? : Bool
            self != InProgress
          end
        end

        # Один прогон CI (workflow run / pipeline) в общем виде.
        record Run,
          id : String,   # идентификатор прогона у провайдера
          name : String, # отображаемое имя ("spec", "pipeline #7")
          state : RunState,
          failure_reason : String = "", # слово провайдера (conclusion / status)
          web_url : String = "",        # ссылка на прогон ("" — нет)
          sha : String? = nil,          # коммит прогона (GitLab; nil — не известен)
          project_id : String = ""      # GitLab: числовой id проекта (добор логов)

        # Результат одной проверки статуса коммита.
        record Check,
          status : Status, # Pending / Success / Failure — вердикт
          detail : String, # человекочитаемое пояснение
          runs : Array(Run) = [] of Run,
          permanent_error : Bool = false # Error, который ретраями не решится

        # Результат запроса логов прогона: `text` — лог (может быть пуст),
        # `error` — причина, почему лог недоступен (пуст, когда получен).
        # Ошибка доступа НЕ молчит: пользователь и модель должны видеть,
        # что лог не пришёл и почему.
        record Log, text : String = "", error : String = ""

        # Все прогоны CI коммита `sha`, приведённые к общему виду. Пока ни
        # одного — Pending. Недоступность источника — Error: transient
        # (permanent_error = false — стоит ретраить) или перманентный
        # (например, отказ в доступе без перспективы внутри сессии).
        abstract def runs(sha : String) : Check

        # Лог первого упавшего прогона из `check` (см. Log).
        abstract def failure_log(check : Check) : Log

        # Универсальная агрегация прогонов в вердикт: Pending пока хоть
        # что-то идёт, Failure если хоть один упал, иначе Success. Слова в
        # detail зависят от провайдера (empty_detail / noun), сами прогоны
        # уже нормализованы адаптером.
        def self.aggregate(runs : Array(Run), empty_detail : String, noun : String) : {Status, String}
          return {Status::Pending, empty_detail} if runs.empty?
          in_progress = [] of String
          failed = [] of String
          passed = 0
          runs.each do |run|
            case run.state
            when .in_progress?
              in_progress << run.name
            when .failed?
              label = run.failure_reason.empty? ? run.name : "#{run.name} (#{run.failure_reason})"
              failed << label
            else
              passed += 1
            end
          end
          unless in_progress.empty?
            return {Status::Pending, "in progress: #{in_progress.join(", ")}"}
          end
          if failed.empty?
            {Status::Success, "#{passed} #{noun} passed"}
          else
            {Status::Failure, failed.join(", ")}
          end
        end
      end
    end
  end
end
