require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::PkgVersioned do
  it "résout `latest` par la vraie version et installe server + client" do
    shell = FakeShell.new
    shell.stub(/pkg rquery/, stdout: "11.4.2 mariadb114-server\n")
    shell.stub(/pkg info -e/, exit_code: 1) # rien d'installé
    result = prim("pkg-versioned").apply(
      shell, apply_params("{base: mariadb, version: latest}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/pkg install -y mariadb114-server mariadb114-client/).should be_true
  end

  it "respecte `only: server` (pas de client)" do
    shell = FakeShell.new
    shell.stub(/pkg info -e/, exit_code: 1)
    result = prim("pkg-versioned").apply(
      shell, apply_params("{base: postgresql, version: 17, only: server}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/pkg install -y postgresql17-server$/).should be_true
  end

  it "skip si tout est déjà installé" do
    shell = FakeShell.new
    shell.stub(/pkg info -e/, exit_code: 0) # tout présent
    result = prim("pkg-versioned").apply(
      shell, apply_params("{base: mariadb, version: 114}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/pkg install/).should be_false
  end

  it "échoue proprement si aucun paquet -server dans le dépôt (latest)" do
    shell = FakeShell.new
    shell.stub(/pkg rquery/, stdout: "") # rien trouvé
    result = prim("pkg-versioned").apply(
      shell, apply_params("{base: mariadb, version: latest}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
  end
end
