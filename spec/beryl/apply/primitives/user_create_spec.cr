require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::UserCreate do
  it "skip si l'utilisateur existe déjà" do
    shell = FakeShell.new
    shell.stub(/pw show/, exit_code: 0)
    result = prim("user-create").apply(shell, apply_params("name: deploy"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/pw useradd/).should be_false
  end

  it "crée l'utilisateur absent avec shell et groupes" do
    shell = FakeShell.new
    shell.stub(/pw show/, exit_code: 1)
    result = prim("user-create").apply(
      shell,
      apply_params("{name: deploy, shell: /usr/local/bin/zsh, groups: [wheel, www]}"),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/pw useradd -n deploy -m/).should be_true
    shell.ran?(/-s '?\/usr\/local\/bin\/zsh'?/).should be_true
    shell.ran?(/-G wheel,www/).should be_true
  end

  it "n'effectue rien en dry-run" do
    shell = FakeShell.new
    shell.stub(/pw show/, exit_code: 1)
    result = prim("user-create").apply(shell, apply_params("name: deploy"), dry_run: true, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/pw useradd/).should be_false
  end
end
