require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::PostgresqlInitdb do
  it "lance initdb si le cluster n'est pas initialisé" do
    shell = FakeShell.new
    shell.stub(%r{ls /var/db/postgres}, exit_code: 1) # pas de PG_VERSION
    result = prim("postgresql-initdb").apply(shell, apply_params("{}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/service postgresql initdb/).should be_true
  end

  it "skip si le cluster est déjà initialisé (idempotent)" do
    shell = FakeShell.new
    shell.stub(%r{ls /var/db/postgres}, exit_code: 0)
    result = prim("postgresql-initdb").apply(shell, apply_params("{}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/initdb/).should be_false
  end
end
