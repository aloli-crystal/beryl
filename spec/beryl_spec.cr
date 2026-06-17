require "./spec_helper"

describe Beryl do
  # On ne fige pas une version précise — elle change à chaque bump
  # via shard.yml et le macro `read_file` (cf. `src/beryl/version.cr`).
  # Format : `MAJEUR.MINEUR.PATCH` + un 4ᵉ digit OPTIONNEL `.BUILD` (numéro de
  # build d'itération, remis à 0 au commit). On vérifie juste la validité.
  it "expose une version au format MAJEUR.MINEUR.PATCH(.BUILD)" do
    Beryl::VERSION.should match(/^\d+\.\d+\.\d+(\.\d+)?$/)
  end
end
