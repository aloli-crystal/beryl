require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::GitClone do
  it "clone en tant que user si la destination est absente" do
    shell = FakeShell.new
    shell.stub(/test -e/, exit_code: 1) # dest absente
    result = prim("git-clone").apply(
      shell,
      apply_params("{repo: https://github.com/ohmyzsh/ohmyzsh.git, dest: /home/deploy/.oh-my-zsh, user: deploy}"),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(%r{sudo -u deploy git clone --depth=1}).should be_true
  end

  it "skip si la destination existe déjà (idempotent)" do
    shell = FakeShell.new
    shell.stub(/test -e/, exit_code: 0) # dest présente
    result = prim("git-clone").apply(
      shell,
      apply_params("{repo: https://github.com/ohmyzsh/ohmyzsh.git, dest: /home/deploy/.oh-my-zsh}"),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/git clone/).should be_false
  end

  it "clone sans user (directement) si user absent" do
    shell = FakeShell.new
    shell.stub(/test -e/, exit_code: 1)
    result = prim("git-clone").apply(
      shell,
      apply_params("{repo: https://x/r.git, dest: /opt/r}"),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/git clone --depth=1/).should be_true
    shell.ran?(/sudo -u/).should be_false
  end
end
