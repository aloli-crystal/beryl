require "../../spec_helper"
require "../../../src/beryl/cli/dns_setup"

describe Beryl::CLI::DnsSetup do
  describe ".ipv6_block_64" do
    it "déduit le /64 d'une adresse compressée en fin (cas OVH usuel)" do
      Beryl::CLI::DnsSetup.ipv6_block_64("2001:41d0:306:2b67::1")
        .should eq("2001:41d0:306:2b67::/64")
    end

    it "déduit le /64 quand la compression est au milieu" do
      # `::` couvre des groupes nuls AVANT le 4e hextet → le 4e doit
      # être complété à 0, pas pris dans la partie droite.
      Beryl::CLI::DnsSetup.ipv6_block_64("2001:41d0:306::2b67:1")
        .should eq("2001:41d0:306:0::/64")
    end

    it "déduit le /64 d'une adresse pleinement développée" do
      Beryl::CLI::DnsSetup.ipv6_block_64("2001:41d0:0306:2b67:0:0:0:1")
        .should eq("2001:41d0:0306:2b67::/64")
    end

    it "ignore un éventuel suffixe /prefix déjà présent" do
      Beryl::CLI::DnsSetup.ipv6_block_64("2001:41d0:306:2b67::1/128")
        .should eq("2001:41d0:306:2b67::/64")
    end
  end
end
