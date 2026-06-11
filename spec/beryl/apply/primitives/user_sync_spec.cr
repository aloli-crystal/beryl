require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::UserSync do
  it "ajoute le user aux groupes manquants (additif)" do
    shell = FakeShell.new
    shell.stub(/getent passwd deploy/, stdout: "deploy:*:1001:1001::/home/deploy:/bin/csh")
    shell.stub(/id -Gn deploy/, stdout: "deploy") # pas encore dans wheel
    result = prim("user-sync").apply(
      shell, apply_params("{name: deploy, secondary_groups: [wheel]}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/pw groupmod wheel -m deploy/).should be_true
  end

  it "skip si déjà membre des groupes voulus" do
    shell = FakeShell.new
    shell.stub(/getent passwd deploy/, stdout: "deploy:*:1001:1001::/home/deploy:/bin/csh")
    shell.stub(/id -Gn deploy/, stdout: "deploy wheel www") # déjà dans wheel
    result = prim("user-sync").apply(
      shell, apply_params("{name: deploy, secondary_groups: [wheel]}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/pw groupmod/).should be_false
  end

  it "ne retire JAMAIS d'un groupe non listé" do
    shell = FakeShell.new
    shell.stub(/getent passwd deploy/, stdout: "deploy:*:1001:1001::/home/deploy:/bin/csh")
    shell.stub(/id -Gn deploy/, stdout: "deploy www") # www non listé → on n'y touche pas
    prim("user-sync").apply(
      shell, apply_params("{name: deploy, secondary_groups: [wheel]}"), dry_run: false, context: ctx)
    shell.ran?(/groupmod www/).should be_false
  end

  it "crée le compte absent avec ses groupes et shell" do
    shell = FakeShell.new
    shell.stub(/getent passwd nouveau/, stdout: "") # absent
    result = prim("user-sync").apply(
      shell, apply_params("{name: nouveau, secondary_groups: [wheel], shell: /bin/sh}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(%r{pw useradd -n nouveau -m -G wheel -s /bin/sh}).should be_true
  end

  it "supprime le compte avec state: absent (home conservé)" do
    shell = FakeShell.new
    shell.stub(/getent passwd vieux/, stdout: "vieux:*:1005:1005::/home/vieux:/bin/sh")
    result = prim("user-sync").apply(
      shell, apply_params("{name: vieux, state: absent}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/pw userdel vieux/).should be_true
    shell.ran?(/-r/).should be_false # pas de suppression du home
  end

  it "skip absent si le compte n'existe déjà plus" do
    shell = FakeShell.new
    shell.stub(/getent passwd vieux/, stdout: "")
    result = prim("user-sync").apply(
      shell, apply_params("{name: vieux, state: absent}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/pw userdel/).should be_false
  end
end
