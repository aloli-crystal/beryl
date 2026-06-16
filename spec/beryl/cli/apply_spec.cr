require "../../spec_helper"
require "../../../src/beryl/cli/apply"

describe Beryl::CLI::Apply do
  describe ".ensure_connection_fields" do
    it "insère ssh_host + proxy_jump avant apply_recipes quand absents" do
      yaml = <<-YAML
      provider: ovh
      freebsd:
        hostname: bi

      apply_recipes:
        - vrack-interface: { ip: 192.168.42.32 }
      YAML
      updated, changed = Beryl::CLI::Apply.ensure_connection_fields(yaml, "192.168.42.32", "admin@zsbg.quimeo.net")
      changed.should be_true
      updated.should contain("ssh_host: 192.168.42.32")
      updated.should contain("proxy_jump: admin@zsbg.quimeo.net")
      # insérés AVANT apply_recipes, dans l'ordre ssh_host puis proxy_jump
      updated.index("ssh_host:").not_nil!.should be < updated.index("proxy_jump:").not_nil!
      updated.index("proxy_jump:").not_nil!.should be < updated.index("apply_recipes:").not_nil!
    end

    it "met à jour les valeurs existantes sans dupliquer" do
      yaml = "ssh_host: 192.168.42.30\nproxy_jump: admin@old.net\nprovider: ovh\n"
      updated, changed = Beryl::CLI::Apply.ensure_connection_fields(yaml, "192.168.42.32", "admin@zsbg.quimeo.net")
      changed.should be_true
      updated.should contain("ssh_host: 192.168.42.32")
      updated.should_not contain("192.168.42.30")
      updated.should_not contain("old.net")
      updated.scan(/ssh_host:/).size.should eq(1) # pas de doublon
    end

    it "no-op si déjà aux bonnes valeurs" do
      yaml = "ssh_host: 192.168.42.32\nproxy_jump: admin@zsbg.quimeo.net\nprovider: ovh\n"
      _, changed = Beryl::CLI::Apply.ensure_connection_fields(yaml, "192.168.42.32", "admin@zsbg.quimeo.net")
      changed.should be_false
    end

    it "ajoute en fin de fichier s'il n'y a pas d'apply_recipes" do
      yaml = "provider: ovh\nfreebsd:\n  hostname: x\n"
      updated, changed = Beryl::CLI::Apply.ensure_connection_fields(yaml, "10.0.0.1", "u@b")
      changed.should be_true
      updated.should contain("ssh_host: 10.0.0.1")
      updated.should contain("proxy_jump: u@b")
    end
  end

  describe ".bastion_ip_for" do
    it "déduit le z du datacentre = <préfixe>.<dizaine>" do
      Beryl::CLI::Apply.bastion_ip_for("192.168.42.31").should eq("192.168.42.3") # DC3
      Beryl::CLI::Apply.bastion_ip_for("192.168.42.11").should eq("192.168.42.1") # DC1
      Beryl::CLI::Apply.bastion_ip_for("192.168.42.22").should eq("192.168.42.2") # DC2
    end

    it "nil pour les IP sans datacentre (dizaine 0) ou malformées" do
      Beryl::CLI::Apply.bastion_ip_for("192.168.42.4").should be_nil # builder
      Beryl::CLI::Apply.bastion_ip_for("192.168.42.3").should be_nil # un z lui-même
      Beryl::CLI::Apply.bastion_ip_for("pas-une-ip").should be_nil
    end
  end
end
