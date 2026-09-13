require "../spec_helper"

# Integration specs for the CI access ports against the real GitHub /
# GitLab APIs — read-only queries to public projects, so they run without
# any credentials (a GITHUB_TOKEN / GITLAB_TOKEN in the environment is
# used opportunistically for higher rate limits).
#
# Gated behind H2CODE_CI_INTEGRATION=1 (`rake spec:ci_port`) — the normal
# `rake spec` / CI matrix must not depend on the network. The commit under
# test is bootstrapped at runtime: the most recent run / pipeline is looked
# up first and its head sha is fed through the port, so the specs never
# depend on a hardcoded (and eventually stale) sha.

module H2code::Tools
  if ENV["H2CODE_CI_INTEGRATION"]? == "1"
    describe "CI port integration (network, read-only)" do
      it "GithubClient checks a real commit's Actions runs" do
        repo = Ci::RepoInfo.new(Ci::Provider::Github, "github.com", "crystal-lang/crystal")
        bootstrap = Ci::GithubApi.new(ENV["GITHUB_TOKEN"]? || ENV["GH_TOKEN"]?)
        res = bootstrap.get("/repos/#{repo.path}/actions/runs?per_page=1")
        res.status_code.should eq(200)
        sha = JSON.parse(res.body)["workflow_runs"].as_a.first["head_sha"].to_s

        client = Ci::GithubClient.new(repo, bootstrap,
          Ci::GithubCli.new(->Ci.run_shell(String, String), Dir.current))
        check = client.runs(sha)

        check.status.error?.should be_false
        check.runs.should_not be_empty
        check.detail.should_not be_empty
      end

      it "GitlabClient checks a real commit's pipelines" do
        repo = Ci::RepoInfo.new(Ci::Provider::Gitlab, "gitlab.com", "gitlab-org/gitlab-foss")
        bootstrap = Ci::GitlabApi.new("https://gitlab.com",
          ENV["GITLAB_TOKEN"]? || ENV["GITLAB_PRIVATE_TOKEN"]?)
        res = bootstrap.get("/projects/#{repo.gitlab_project_ref}/pipelines?per_page=1")
        res.status_code.should eq(200)
        sha = JSON.parse(res.body).as_a.first["sha"].to_s

        runner = ->Ci.run_shell(String, String)
        client = Ci::GitlabClient.new(repo, bootstrap,
          Ci::GitlabCli.new(runner, Dir.current, repo.host), -> { false })
        check = client.runs(sha)

        check.status.error?.should be_false
        check.runs.should_not be_empty
        check.runs.first.web_url.should contain("gitlab.com/gitlab-org/gitlab-foss/-/pipelines/")
      end
    end
  else
    puts "skipping CI port integration specs (set H2CODE_CI_INTEGRATION=1, e.g. `rake spec:ci_port`)"
  end
end
