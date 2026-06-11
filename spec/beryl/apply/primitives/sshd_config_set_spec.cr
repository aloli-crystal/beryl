require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::SshdConfigSet do
  it "pose la directive, valide et recharge sshd" do
    shell = FakeShell.new
    shell.stub(/cat .*beryl\.conf/, stdout: "")
    result = prim("sshd-config-set").apply(
      shell, apply_params(%({key: PermitRootLogin, value: "no"})), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.writes.any? { |w| w.content.includes?("PermitRootLogin no") }.should be_true
    shell.ran?(/sshd -t/).should be_true
    shell.ran?(/service sshd reload/).should be_true
  end

  it "skip si la directive est déjà à la bonne valeur" do
    shell = FakeShell.new
    shell.stub(/cat .*beryl\.conf/, stdout: "PermitRootLogin no\n")
    result = prim("sshd-config-set").apply(
      shell, apply_params(%({key: PermitRootLogin, value: "no"})), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.writes.should be_empty
    shell.ran?(/service sshd reload/).should be_false
  end

  it "met à jour une directive existante en conservant les autres" do
    shell = FakeShell.new
    shell.stub(/cat .*beryl\.conf/, stdout: "PasswordAuthentication no\nPermitRootLogin yes\n")
    result = prim("sshd-config-set").apply(
      shell, apply_params(%({key: PermitRootLogin, value: "no"})), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    written = shell.writes.first.content
    written.should contain("PasswordAuthentication no")
    written.should contain("PermitRootLogin no")
    written.should_not contain("PermitRootLogin yes")
  end

  it "ajoute l'Include en tête du sshd_config s'il manque (sinon drop-in inerte)" do
    shell = FakeShell.new
    shell.stub(/cat .*beryl\.conf/, stdout: "PermitRootLogin no\n") # directive déjà bonne
    shell.stub(/grep.*Include/, exit_code: 1)                       # Include ABSENT
    result = prim("sshd-config-set").apply(
      shell, apply_params(%({key: PermitRootLogin, value: "no"})), dry_run: false, context: ctx)
    # même directive déjà à la bonne valeur : l'ajout de l'Include force quand même l'application + reload.
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(%r{Include /etc/ssh/sshd_config\.d/\*\.conf}).should be_true
    shell.ran?(/service sshd reload/).should be_true
  end

  it "n'ajoute pas l'Include s'il est déjà présent (idempotent)" do
    shell = FakeShell.new
    shell.stub(/cat .*beryl\.conf/, stdout: "")
    shell.stub(/grep.*Include/, exit_code: 0) # Include présent
    prim("sshd-config-set").apply(
      shell, apply_params(%({key: X11Forwarding, value: "no"})), dry_run: false, context: ctx)
    # pas de réécriture du sshd_config principal (le prepend echo l'Include).
    shell.ran?(%r{Include /etc/ssh/sshd_config\.d/\*\.conf}).should be_false
  end
end
