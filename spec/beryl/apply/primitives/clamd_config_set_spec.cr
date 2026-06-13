require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::ClamdConfigSet do
  it "pose une directive et redémarre clamd s'il tourne" do
    shell = FakeShell.new
    shell.stub(/cat .*clamd\.conf/, stdout: "")
    shell.stub(/onestatus/, exit_code: 0) # clamd tourne
    result = prim("clamd-config-set").apply(
      shell, apply_params(%({key: TCPSocket, value: "3310"})), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.writes.any? { |w| w.content.includes?("TCPSocket 3310") }.should be_true
    shell.ran?(/service clamav_clamd restart/).should be_true
  end

  it "ne redémarre pas clamd s'il n'est pas (encore) lancé" do
    shell = FakeShell.new
    shell.stub(/cat .*clamd\.conf/, stdout: "")
    shell.stub(/onestatus/, exit_code: 1) # clamd arrêté (install)
    result = prim("clamd-config-set").apply(
      shell, apply_params(%({key: LocalSocket, value: /var/run/clamav/clamd.sock})), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/restart/).should be_false
  end

  it "skip si la directive est déjà à la bonne valeur" do
    shell = FakeShell.new
    shell.stub(/cat .*clamd\.conf/, stdout: "TCPSocket 3310\n")
    result = prim("clamd-config-set").apply(
      shell, apply_params(%({key: TCPSocket, value: "3310"})), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.writes.should be_empty
  end

  it "résout value_from_command (ex. IP tailscale)" do
    shell = FakeShell.new
    shell.stub(/cat .*clamd\.conf/, stdout: "")
    shell.stub(/tailscale ip/, stdout: "100.64.0.5\n")
    shell.stub(/onestatus/, exit_code: 1)
    result = prim("clamd-config-set").apply(
      shell, apply_params(%({key: TCPAddr, value_from_command: "tailscale ip -4"})), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.writes.any? { |w| w.content.includes?("TCPAddr 100.64.0.5") }.should be_true
  end
end
