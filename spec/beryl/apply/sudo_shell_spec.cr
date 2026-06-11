require "../../spec_helper"
require "../../support/fake_shell"

describe Beryl::Apply::SudoShell do
  it "enrobe chaque commande dans `sudo sh -c`" do
    inner = FakeShell.new
    sudo = Beryl::Apply::SudoShell.new(inner)
    sudo.exec("pkg info -e zsh")
    inner.ran?(/sudo sh -c/).should be_true
  end

  it "écrit un fichier via temp + `sudo install` (escalade root)" do
    inner = FakeShell.new
    inner.stub(/mktemp/, stdout: "/tmp/tmp.AbC\n")
    sudo = Beryl::Apply::SudoShell.new(inner)
    sudo.write_file("/etc/ssh/sshd_config.d/10-foo.conf", "Port 22", mode: "0644")
    inner.ran?(/mktemp/).should be_true
    inner.ran?(%r{sudo install -m 0644 /tmp/tmp.AbC /etc/ssh/sshd_config.d/10-foo.conf}).should be_true
    inner.ran?(%r{rm -f /tmp/tmp.AbC}).should be_true
  end
end
