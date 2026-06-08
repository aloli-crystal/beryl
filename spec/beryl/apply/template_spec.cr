require "../../spec_helper"

describe Beryl::Apply::Template do
  it "substitue les placeholders connus" do
    Beryl::Apply::Template.render("{{ a }}-{{b}}", {"a" => "x", "b" => "y"}).should eq("x-y")
  end

  it "laisse intact un texte sans placeholder" do
    Beryl::Apply::Template.render("rien à substituer", {} of String => String).should eq("rien à substituer")
  end

  it "lève UnknownVariable pour une variable absente" do
    expect_raises(Beryl::Apply::Template::UnknownVariable, /inconnue|non définie/) do
      Beryl::Apply::Template.render("{{ manquante }}", {} of String => String)
    end
  end

  it "détecte la présence d'un placeholder" do
    Beryl::Apply::Template.has_placeholder?("{{ x }}").should be_true
    Beryl::Apply::Template.has_placeholder?("plat").should be_false
  end
end
