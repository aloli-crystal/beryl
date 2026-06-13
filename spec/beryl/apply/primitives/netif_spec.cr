require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::Netif do
  it "configure l'IP (persistant + immédiat) si absente" do
    shell = FakeShell.new
    shell.stub(/grep -qw 192.168.42.10/, exit_code: 1) # l'IP n'est pas posée
    shell.stub(/sysrc -n/, stdout: "")
    result = prim("netif").apply(
      shell, apply_params("{iface: ix1, ip: 192.168.42.10}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/ifconfig_ix1=inet 192.168.42.10/).should be_true # sysrc (valeur quotée)
    shell.ran?(%r{ifconfig ix1 inet 192.168.42.10 netmask 255.255.255.0}).should be_true
  end

  it "skip si l'IP et le rc.conf sont déjà bons (idempotent)" do
    shell = FakeShell.new
    shell.stub(/grep -qw 192.168.42.10/, exit_code: 0)                         # IP présente
    shell.stub(/sysrc -n/, stdout: "inet 192.168.42.10 netmask 255.255.255.0") # rc à jour
    result = prim("netif").apply(
      shell, apply_params("{iface: ix1, ip: 192.168.42.10}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/ifconfig_ix1=inet/).should be_false
  end

  it "échoue si `ip` est vide" do
    shell = FakeShell.new
    result = prim("netif").apply(
      shell, apply_params("{iface: ix1, ip: \"\"}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
  end
end
