require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::Freshclam do
  it "télécharge la base si elle est absente" do
    shell = FakeShell.new
    shell.stub(%r{ls /var/db/clamav}, exit_code: 1) # pas de base
    result = prim("freshclam").apply(shell, apply_params("{}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/^freshclam$/).should be_true
  end

  it "skip si une base est déjà présente (idempotent)" do
    shell = FakeShell.new
    shell.stub(%r{ls /var/db/clamav}, exit_code: 0)
    result = prim("freshclam").apply(shell, apply_params("{}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/freshclam/).should be_false
  end
end
