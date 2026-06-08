require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::HeadscaleStateCommit do
  it "fail si le repo n'est pas cloné sur le host" do
    shell = FakeShell.new
    shell.stub(/test -d.*\.git/, exit_code: 1)
    result = prim("headscale-state-commit").apply(
      shell,
      apply_params(%({message: "PORT 22 OPEN host=loulou"})),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
    result.message.should contain("headscale-backup")
  end

  it "exécute le pipeline flock + append + commit + push" do
    shell = FakeShell.new
    shell.stub(/test -d.*\.git/, exit_code: 0)
    shell.stub(/hostname -s/, stdout: "rbx\n", exit_code: 0)
    shell.stub(/flock -n 9/, exit_code: 0)

    result = prim("headscale-state-commit").apply(
      shell,
      apply_params(%({message: "PORT 22 PUBLIC OPEN host=loulou raison=deploy"})),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/flock -n 9/).should be_true
    shell.ran?(/git add.*audit\.log/).should be_true
    shell.ran?(/git commit/).should be_true
    shell.ran?(/git push/).should be_true
  end

  it "dry-run n'écrit pas" do
    shell = FakeShell.new
    result = prim("headscale-state-commit").apply(
      shell,
      apply_params(%({message: "test"})),
      dry_run: true, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/git commit/).should be_false
  end
end
