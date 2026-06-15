require "../../spec_helper"
require "../../../src/beryl/cli/raid_controller"

describe Beryl::CLI::RaidController do
  describe ".controller_count" do
    it "parse « Controller Count = N »" do
      Beryl::CLI::RaidController.controller_count("Status = Success\nController Count = 1\n").should eq(1)
    end
    it "retourne 0 si absent" do
      Beryl::CLI::RaidController.controller_count("rien d'utile").should eq(0)
    end
  end

  describe ".parse_drive_slots" do
    it "extrait les EID:Slt des disques (ignore en-tête et séparateurs)" do
      sample = <<-OUT
        EID:Slt DID State DG     Size Intf Med SED PI SeSz Model Sp Type
        ----------------------------------------------------------------
        252:0     9 Onln   0 893.137 GB SATA SSD N   N  512B SAMSUNG U -
        252:1    10 Onln   0 893.137 GB SATA SSD N   N  512B SAMSUNG U -
        252:2    11 Onln   0 893.137 GB SATA SSD N   N  512B SAMSUNG U -
        252:3    12 Onln   0 893.137 GB SATA SSD N   N  512B SAMSUNG U -
        ----------------------------------------------------------------
        OUT
      Beryl::CLI::RaidController.parse_drive_slots(sample).should eq(["252:0", "252:1", "252:2", "252:3"])
    end
  end

  describe ".raid_type" do
    it "mappe les niveaux matériels" do
      Beryl::CLI::RaidController.raid_type(0).should eq("raid0")
      Beryl::CLI::RaidController.raid_type(1).should eq("raid1")
      Beryl::CLI::RaidController.raid_type(10).should eq("raid10")
    end
    it "refuse un niveau non matériel (7 = raidz3, ZFS only)" do
      expect_raises(ArgumentError, /ne gère pas RAID 7/) do
        Beryl::CLI::RaidController.raid_type(7)
      end
    end
  end

  describe ".create_vd_command" do
    it "construit la commande add vd avec les slots" do
      Beryl::CLI::RaidController.create_vd_command(0, 10, ["252:0", "252:1", "252:2", "252:3"])
        .should eq("/c0 add vd type=raid10 drives=252:0,252:1,252:2,252:3")
    end
  end
end
