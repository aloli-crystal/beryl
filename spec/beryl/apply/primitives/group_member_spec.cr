require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::GroupMember do
  it "ajoute le user au groupe quand il n'en est pas membre" do
    shell = FakeShell.new
    shell.stub(/getent passwd clamav/, stdout: "clamav:*:106:106:Clam Antivirus:/var/db/clamav:/usr/sbin/nologin")
    shell.stub(/getent group www/, stdout: "www:*:80:")
    shell.stub(/id -Gn clamav/, stdout: "clamav")
    result = prim("group-member").apply(shell, apply_params("{user: clamav, group: www}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(%r{pw groupmod www -m clamav}).should be_true
  end

  it "skip si le user est déjà membre du groupe" do
    shell = FakeShell.new
    shell.stub(/getent passwd clamav/, stdout: "clamav:*:106:106:Clam Antivirus:/var/db/clamav:/usr/sbin/nologin")
    shell.stub(/getent group www/, stdout: "www:*:80:clamav")
    shell.stub(/id -Gn clamav/, stdout: "clamav www")
    result = prim("group-member").apply(shell, apply_params("{user: clamav, group: www}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/pw groupmod/).should be_false
  end

  it "skip si le user est absent" do
    shell = FakeShell.new
    shell.stub(/getent passwd ghost/, stdout: "")
    result = prim("group-member").apply(shell, apply_params("{user: ghost, group: www}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/pw groupmod/).should be_false
  end

  it "skip si le groupe est absent" do
    shell = FakeShell.new
    shell.stub(/getent passwd clamav/, stdout: "clamav:*:106:106:Clam Antivirus:/var/db/clamav:/usr/sbin/nologin")
    shell.stub(/getent group www/, stdout: "")
    result = prim("group-member").apply(shell, apply_params("{user: clamav, group: www}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/pw groupmod/).should be_false
  end
end
