require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::UserShell do
  it "change le shell quand il diffère" do
    shell = FakeShell.new
    shell.stub(/getent passwd deploy/, stdout: "deploy:*:1001:1001:Deploy:/home/deploy:/bin/csh")
    result = prim("user-shell").apply(shell, apply_params("{user: deploy, shell: /usr/local/bin/zsh}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(%r{pw usermod deploy -s /usr/local/bin/zsh}).should be_true
  end

  it "skip si le shell est déjà le bon" do
    shell = FakeShell.new
    shell.stub(/getent passwd deploy/, stdout: "deploy:*:1001:1001:Deploy:/home/deploy:/usr/local/bin/zsh")
    result = prim("user-shell").apply(shell, apply_params("{user: deploy, shell: /usr/local/bin/zsh}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/pw usermod/).should be_false
  end

  it "skip si le user est absent" do
    shell = FakeShell.new
    shell.stub(/getent passwd ghost/, stdout: "")
    result = prim("user-shell").apply(shell, apply_params("{user: ghost, shell: /bin/sh}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/pw usermod/).should be_false
  end
end
