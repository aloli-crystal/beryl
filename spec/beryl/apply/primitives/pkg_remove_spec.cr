require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::PkgRemove do
  it "supprime uniquement les packages présents" do
    shell = FakeShell.new
    shell.stub(/pkg info/, stdout: "git\nsendmail\n")
    result = prim("pkg-remove").apply(shell, apply_params("packages: [sendmail, telnet]"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    result.message.should contain("sendmail")
    result.message.should_not contain("telnet")
    shell.ran?(/pkg delete -y/).should be_true
  end

  it "skip si aucun package n'est installé" do
    shell = FakeShell.new
    shell.stub(/pkg info/, stdout: "git\n")
    result = prim("pkg-remove").apply(shell, apply_params("packages: [telnet]"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/pkg delete/).should be_false
  end

  it "n'effectue rien en dry-run" do
    shell = FakeShell.new
    shell.stub(/pkg info/, stdout: "sendmail\n")
    result = prim("pkg-remove").apply(shell, apply_params("packages: [sendmail]"), dry_run: true, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/pkg delete/).should be_false
  end
end
