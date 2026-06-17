require "../../spec_helper"
require "../../../src/beryl/cli/vrack"

describe Beryl::CLI::Vrack do
  describe ".upsert_network_field" do
    it "met à jour une clé existante du bloc network:" do
      input = "provider: ovh\nnetwork:\n  vrack_ip: 192.168.42.31\n  proxy_jump: old@bast.net\nfreebsd:\n  hostname: x\n"
      out = Beryl::CLI::Vrack.upsert_network_field(input, "proxy_jump", "admin@zsbg.quimeo.net")
      out.should eq("provider: ovh\nnetwork:\n  vrack_ip: 192.168.42.31\n  proxy_jump: admin@zsbg.quimeo.net\nfreebsd:\n  hostname: x\n")
    end

    it "ajoute une clé en fin de bloc network: existant" do
      input = "network:\n  vrack_ip: 192.168.42.31\napply_recipes:\n  - clamav\n"
      out = Beryl::CLI::Vrack.upsert_network_field(input, "proxy_jump", "admin@z.net")
      out.should eq("network:\n  vrack_ip: 192.168.42.31\n  proxy_jump: admin@z.net\napply_recipes:\n  - clamav\n")
    end

    it "crée le bloc network: avant apply_recipes: s'il est absent" do
      input = "provider: ovh\napply_recipes:\n  - clamav\n"
      out = Beryl::CLI::Vrack.upsert_network_field(input, "bastion", "true")
      out.should eq("provider: ovh\nnetwork:\n  bastion: true\napply_recipes:\n  - clamav\n")
    end

    it "crée le bloc network: en fin si pas d'apply_recipes:" do
      input = "provider: ovh\n"
      out = Beryl::CLI::Vrack.upsert_network_field(input, "bastion", "false")
      out.should eq("provider: ovh\nnetwork:\n  bastion: false\n")
    end
  end

  describe ".remove_network_field" do
    it "retire une clé du bloc network:" do
      input = "network:\n  vrack_ip: 192.168.42.31\n  proxy_jump: admin@z.net\napply_recipes:\n  - clamav\n"
      out = Beryl::CLI::Vrack.remove_network_field(input, "proxy_jump")
      out.should eq("network:\n  vrack_ip: 192.168.42.31\napply_recipes:\n  - clamav\n")
    end

    it "retire le bloc network: entier si la dernière clé part" do
      input = "provider: ovh\nnetwork:\n  proxy_jump: admin@z.net\napply_recipes:\n  - clamav\n"
      out = Beryl::CLI::Vrack.remove_network_field(input, "proxy_jump")
      out.should eq("provider: ovh\napply_recipes:\n  - clamav\n")
    end

    it "no-op si la clé est absente" do
      input = "network:\n  vrack_ip: 192.168.42.31\n"
      Beryl::CLI::Vrack.remove_network_field(input, "proxy_jump").should eq(input)
    end
  end

  describe ".derive_proxy_jump" do
    it "complète un nom court de bastion avec le domaine" do
      Beryl::CLI::Vrack.derive_proxy_jump("admin", "zsbg", "quimeo.net").should eq("admin@zsbg.quimeo.net")
    end

    it "respecte un bastion déjà en FQDN" do
      Beryl::CLI::Vrack.derive_proxy_jump("deploy", "bast.example.net", "quimeo.net").should eq("deploy@bast.example.net")
    end
  end
end
