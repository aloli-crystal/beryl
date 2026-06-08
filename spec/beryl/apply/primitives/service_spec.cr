require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::ServiceEnable do
  it "active et démarre un service ni activé ni lancé" do
    shell = FakeShell.new
    shell.stub(/sysrc -n/, stdout: "NO")
    shell.stub(/service nginx onestatus/, exit_code: 1)
    result = prim("service-enable").apply(shell, apply_params("name: nginx"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/sysrc nginx_enable=YES/).should be_true
    shell.ran?(/service nginx start/).should be_true
  end

  it "skip si déjà activé et démarré" do
    shell = FakeShell.new
    shell.stub(/sysrc -n/, stdout: "YES")
    shell.stub(/service nginx onestatus/, exit_code: 0)
    result = prim("service-enable").apply(shell, apply_params("name: nginx"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/sysrc nginx_enable=YES/).should be_false
  end

  it "active sans démarrer si start: false" do
    shell = FakeShell.new
    shell.stub(/sysrc -n/, stdout: "NO")
    shell.stub(/service nginx onestatus/, exit_code: 1)
    result = prim("service-enable").apply(shell, apply_params("{name: nginx, start: false}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/sysrc nginx_enable=YES/).should be_true
    shell.ran?(/service nginx start/).should be_false
  end
end

describe Beryl::Apply::ServiceDisable do
  it "désactive et arrête un service actif" do
    shell = FakeShell.new
    shell.stub(/sysrc -n/, stdout: "YES")
    shell.stub(/service sendmail onestatus/, exit_code: 0)
    result = prim("service-disable").apply(shell, apply_params("name: sendmail"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/sysrc sendmail_enable=NO/).should be_true
    shell.ran?(/service sendmail stop/).should be_true
  end

  it "skip si déjà désactivé et arrêté" do
    shell = FakeShell.new
    shell.stub(/sysrc -n/, stdout: "NO")
    shell.stub(/service sendmail onestatus/, exit_code: 1)
    result = prim("service-disable").apply(shell, apply_params("name: sendmail"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
  end
end
