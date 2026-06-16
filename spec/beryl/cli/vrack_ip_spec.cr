require "../../spec_helper"
require "../../../src/beryl/cli/vrack_ip"

private def entry(host, ip)
  Beryl::CLI::VrackIp::Entry.new(host, ip, "/tmp/#{host}.host.yml")
end

describe Beryl::CLI::VrackIp do
  describe ".collisions" do
    it "repère deux hôtes sur la même IP" do
      cols = Beryl::CLI::VrackIp.collisions([
        entry("ke", "192.168.42.12"),
        entry("han", "192.168.42.12"),
        entry("obi", "192.168.42.11"),
      ])
      cols.keys.should eq(["192.168.42.12"])
      cols["192.168.42.12"].sort.should eq(["han", "ke"])
    end

    it "vide si aucune collision" do
      Beryl::CLI::VrackIp.collisions([entry("a", "192.168.42.1"), entry("b", "192.168.42.2")]).should be_empty
    end
  end

  describe ".out_of_subnet" do
    it "liste les IP hors du /24" do
      oos = Beryl::CLI::VrackIp.out_of_subnet(
        [entry("a", "192.168.42.5"), entry("b", "10.0.0.1")], "192.168.42.0/24")
      oos.map(&.host).should eq(["b"])
    end
  end

  describe ".subnet_prefix" do
    it "extrait le préfixe /24" do
      Beryl::CLI::VrackIp.subnet_prefix("192.168.42.0/24").should eq("192.168.42.")
    end
  end

  describe ".replace_vrack_ip" do
    it "remplace l'IP en préservant le commentaire" do
      line = "  - vrack-interface: { ip: 192.168.42.11 } # app server (via zgra)\n"
      updated, changed = Beryl::CLI::VrackIp.replace_vrack_ip(line, "192.168.42.41")
      changed.should be_true
      updated.should eq("  - vrack-interface: { ip: 192.168.42.41 } # app server (via zgra)\n")
    end

    it "gère le variant avec iface" do
      line = "  - vrack-interface: { ip: 192.168.42.30, iface: ixl1 }\n"
      updated, _ = Beryl::CLI::VrackIp.replace_vrack_ip(line, "192.168.42.32")
      updated.should eq("  - vrack-interface: { ip: 192.168.42.32, iface: ixl1 }\n")
    end

    it "ne change rien si l'IP est déjà la bonne" do
      line = "  - vrack-interface: { ip: 192.168.42.4 }\n"
      _, changed = Beryl::CLI::VrackIp.replace_vrack_ip(line, "192.168.42.4")
      changed.should be_false
    end

    it "signale l'absence de vrack-interface" do
      Beryl::CLI::VrackIp.has_vrack_interface?("freebsd:\n  hostname: x\n").should be_false
      _, changed = Beryl::CLI::VrackIp.replace_vrack_ip("rien ici", "192.168.42.9")
      changed.should be_false
    end
  end

  describe ".render / .parse_registry" do
    it "génère un vrack.yml trié par IP, relisible" do
      yaml = Beryl::CLI::VrackIp.render("pn-1049829", "192.168.42.0/24",
        [entry("obi", "192.168.42.41"), entry("zgra", "192.168.42.1")])
      yaml.index("zgra").not_nil!.should be < yaml.index("obi").not_nil!
      reg = Beryl::CLI::VrackIp.parse_registry(yaml)
      reg["zgra"].should eq("192.168.42.1")
      reg["obi"].should eq("192.168.42.41")
    end
  end
end
