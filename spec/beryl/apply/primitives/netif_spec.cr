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

  it "échoue tôt si l'interface n'existe pas et liste les dispo (rien écrit)" do
    shell = FakeShell.new
    shell.stub(/ifconfig ix1 2>/, exit_code: 1)        # ix1 absent
    shell.stub(/ifconfig -l/, stdout: "igb0 igb1 lo0") # interfaces réelles
    result = prim("netif").apply(
      shell, apply_params("{iface: ix1, ip: 192.168.42.3}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
    result.message.should contain("igb1")
    shell.ran?(/sysrc ifconfig_ix1=/).should be_false # pas d'entrée parasite dans rc.conf
  end

  it "auto-détecte le NIC vRack quand iface vaut auto" do
    shell = FakeShell.new
    shell.stub(/for i in .*ifconfig -l ether/, stdout: "ixl1\n") # 1 seul candidat
    shell.stub(/grep -qw 192.168.42.11/, exit_code: 1)
    shell.stub(/sysrc -n/, stdout: "")
    result = prim("netif").apply(
      shell, apply_params("{iface: auto, ip: 192.168.42.11}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/ifconfig_ixl1=inet 192.168.42.11/).should be_true
  end

  it "échoue (auto) si plusieurs NIC candidats — ambigu" do
    shell = FakeShell.new
    shell.stub(/for i in .*ifconfig -l ether/, stdout: "ixl1\nixl2\n")
    result = prim("netif").apply(
      shell, apply_params("{iface: auto, ip: 192.168.42.11}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
    result.message.should contain("ambig")
  end

  it "échoue (auto) si aucun NIC candidat" do
    shell = FakeShell.new
    shell.stub(/for i in .*ifconfig -l ether/, stdout: "")
    result = prim("netif").apply(
      shell, apply_params("{iface: auto, ip: 192.168.42.11}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
  end
end
