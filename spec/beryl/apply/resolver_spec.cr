require "../../spec_helper"

private RECIPES_ROOT = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "recipes"))
private CENTRAL_DIR  = File.join(RECIPES_ROOT, "central", "recipes")

private def host_dir(name : String) : String
  File.join(RECIPES_ROOT, "hosts", name)
end

private def resolve(host : String) : Array(Beryl::Apply::Recipe)
  Beryl::Apply::Resolver.new(host_dir(host), CENTRAL_DIR).resolve
end

describe Beryl::Apply::Resolver do
  it "retourne une liste vide si le dossier host n'existe pas" do
    Beryl::Apply::Resolver.new(host_dir("inexistant"), CENTRAL_DIR).resolve.should be_empty
  end

  it "résout la fermeture transitive et trie en ordre topologique" do
    order = resolve("basic").map(&.name)
    # base-packages avant ses dépendants ; post-install en dernier.
    order.should eq(["base-packages", "freebsd-updates", "shell-tools", "post-install"])
  end

  it "dédup une recette requise par plusieurs (base-packages une seule fois)" do
    resolve("basic").map(&.name).count("base-packages").should eq(1)
  end

  it "donne priorité à l'override du dossier host sur le dépôt central" do
    recipes = resolve("override")
    base = recipes.find! { |r| r.name == "base-packages" }
    base.source_path.should contain(File.join("hosts", "override"))
    # L'override a 4 packages (dont vim), pas les 3 du central.
    base.steps.first.params["packages"].as_a.map(&.as_s).should contain("vim")
  end

  it "détecte un cycle de dépendances" do
    expect_raises(Beryl::Apply::Resolver::Cycle, /cycle-a|cycle-b/) do
      resolve("cycle")
    end
  end

  it "lève RecipeNotFound en nommant le requérant" do
    expect_raises(Beryl::Apply::Resolver::RecipeNotFound, /requise par `needs-missing`/) do
      resolve("missing")
    end
  end
end
