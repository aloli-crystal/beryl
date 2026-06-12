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

  it "skip si le serveur PostgreSQL n'est pas installé (only: client)" do
    shell = FakeShell.new
    shell.stub(%r{test -f /usr/local/etc/rc.d/postgresql}, exit_code: 1)
    result = prim("postgresql-initdb").apply(shell, apply_params("{}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/initdb/).should be_false
  end
end
