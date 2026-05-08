require "./spec_helper"

describe Beryl do
  # On ne fige pas une version précise — elle change à chaque bump
  # via shard.yml et le macro `read_file` (cf. `src/beryl/version.cr`).
  # On se contente de vérifier le format semver pour s'assurer que
  # le macro a bien retourné quelque chose de valide.
  it "expose une version au format semver" do
    Beryl::VERSION.should match(/^\d+\.\d+\.\d+$/)
  end
end
