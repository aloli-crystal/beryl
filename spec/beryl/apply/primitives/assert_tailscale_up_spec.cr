require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::AssertTailscaleUp do
  it "skip quand tailscale est UP, IP attribuée, et socket assez vieux" do
    shell = FakeShell.new
    shell.stub(/tailscale status/, exit_code: 0)
    shell.stub(/tailscale ip -4/, stdout: "100.64.0.42\n", exit_code: 0)
    shell.stub(/find .*tailscaled.sock/, stdout: "OK\n")
    result = prim("assert-tailscale-up").apply(
      shell, apply_params("{}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    result.message.should contain("100.64.0.42")
  end

  it "fail si tailscale status échoue" do
    shell = FakeShell.new
    shell.stub(/tailscale status/, exit_code: 1)
    result = prim("assert-tailscale-up").apply(
      shell, apply_params("{}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
    result.message.should contain("status")
  end

  it "fail si pas d'IPv4 tailscale" do
    shell = FakeShell.new
    shell.stub(/tailscale status/, exit_code: 0)
    shell.stub(/tailscale ip -4/, stdout: "", exit_code: 0)
    result = prim("assert-tailscale-up").apply(
      shell, apply_params("{}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
    result.message.should contain("IPv4")
  end

  it "fail si la session est trop récente" do
    shell = FakeShell.new
    shell.stub(/tailscale status/, exit_code: 0)
    shell.stub(/tailscale ip -4/, stdout: "100.64.0.7\n", exit_code: 0)
    shell.stub(/find .*tailscaled.sock/, stdout: "TOO_RECENT\n")
    result = prim("assert-tailscale-up").apply(
      shell, apply_params(%({min_uptime_seconds: 30})), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
    result.message.should contain("moins")
  end
end
