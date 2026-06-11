require "../../spec_helper"
require "../../support/fake_shell"

private CENTRAL = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "recipes", "central", "recipes"))

private def central_recipe(name : String) : Beryl::Apply::Recipe
  Beryl::Apply::Recipe.load(File.join(CENTRAL, "#{name}.recipe.yml"))
end

# Primitive de test : enregistre les params reçus (interpolés) et
# annonce `applied`. Enregistrée une fois dans le registre global.
class TestRecorder < Beryl::Apply::Primitive
  class_property last_params = {} of String => YAML::Any

  def name : String
    "test-record"
  end

  def apply(shell : Beryl::Apply::Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Beryl::Apply::Context) : Beryl::Apply::StepResult
    TestRecorder.last_params = params
    Beryl::Apply::StepResult.applied("recorded")
  end
end

Beryl::Apply::Primitive.register(TestRecorder.new)

describe Beryl::Apply::Executor do
  it "exécute les steps et agrège le rapport" do
    shell = FakeShell.new
    shell.stub(/pkg info/, stdout: "") # rien d'installé → tout à installer
    recipes = [central_recipe("base-packages"), central_recipe("freebsd-updates")]
    report = Beryl::Apply::Executor.new(shell, dry_run: false).run(recipes)
    report.total.should eq(2)
    report.applied.should eq(2)
    report.failed.should eq(0)
    shell.ran?(/pkg install -y/).should be_true
  end

  it "n'applique rien en dry-run" do
    shell = FakeShell.new
    shell.stub(/pkg info/, stdout: "")
    report = Beryl::Apply::Executor.new(shell, dry_run: true).run([central_recipe("base-packages")])
    report.applied.should eq(1)
    shell.ran?(/pkg install/).should be_false
  end

  it "interpole {{ var }} depuis arguments (qui priment sur parameters.default)" do
    shell = FakeShell.new
    Beryl::Apply::Executor.new(shell, dry_run: false).run([central_recipe("recorder")])
    TestRecorder.last_params["msg"].as_s.should eq("salut le monde")
  end

  it "les arguments fournis par l'hôte (apply_recipes map) priment sur ceux de la recette" do
    shell = FakeShell.new
    # La fixture recorder utilise la variable `greeting` (default bonjour,
    # argument salut). L'argument hôte doit primer → "coucou le monde".
    host_args = {"recorder" => {"greeting" => "coucou"}}
    Beryl::Apply::Executor.new(shell, dry_run: false).run([central_recipe("recorder")], host_args)
    TestRecorder.last_params["msg"].as_s.should eq("coucou le monde")
  end

  it "lève UnknownPrimitive pour un step inconnu" do
    shell = FakeShell.new
    recipe = Beryl::Apply::Recipe.new(
      name: "bidon",
      description: "",
      requires: [] of String,
      parameters: {} of String => YAML::Any,
      arguments: {} of String => YAML::Any,
      steps: [Beryl::Apply::Step.new(name: "primitive-fantome", params: {} of String => YAML::Any)],
      source_path: "<test>",
    )
    expect_raises(Beryl::Apply::UnknownPrimitive, /primitive-fantome/) do
      Beryl::Apply::Executor.new(shell, dry_run: false).run([recipe])
    end
  end

  it "marque failed et stoppe net sur échec de commande" do
    shell = FakeShell.new
    shell.stub(/pkg info/, stdout: "")
    shell.stub(/pkg install/, exit_code: 1, stderr: "boom")
    report = Beryl::Apply::Executor.new(shell, dry_run: false).run([central_recipe("base-packages")])
    report.failed.should eq(1)
  end
end
