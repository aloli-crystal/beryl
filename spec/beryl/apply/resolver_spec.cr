require "../../spec_helper"

private RECIPES_ROOT = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "recipes"))
private CENTRAL_DIR  = File.join(RECIPES_ROOT, "central", "recipes")

private def resolve(*names : String) : Array(Beryl::Apply::Recipe)
  Beryl::Apply::Resolver.new(CENTRAL_DIR).resolve(names.to_a)
end

describe Beryl::Apply::Resolver do
  it "retourne une liste vide si aucune recette d'entrée" do
    Beryl::Apply::Resolver.new(CENTRAL_DIR).resolve([] of String).should be_empty
  end

  it "résout la fermeture transitive et trie en ordre topologique" do
    order = resolve("post-install").map(&.name)
    # base-packages avant ses dépendants ; post-install en dernier.
    order.should eq(["base-packages", "freebsd-updates", "shell-tools", "post-install"])
  end

  it "dédup une recette requise par plusieurs (base-packages une seule fois)" do
    resolve("post-install").map(&.name).count("base-packages").should eq(1)
  end

  it "résout plusieurs recettes d'entrée (apply_recipes cumulés)" do
    # Deux entrées indépendantes → union dédupliquée, ordre topo global.
    names = resolve("shell-tools", "freebsd-updates").map(&.name)
    names.should contain("base-packages")
    names.should contain("shell-tools")
    names.should contain("freebsd-updates")
  end

  it "détecte un cycle de dépendances" do
    expect_raises(Beryl::Apply::Resolver::Cycle, /cycle-a|cycle-b/) do
      resolve("cycle-a")
    end
  end

  it "lève RecipeNotFound en nommant le requérant" do
    expect_raises(Beryl::Apply::Resolver::RecipeNotFound, /requise par `needs-missing`/) do
      resolve("needs-missing")
    end
  end
end
