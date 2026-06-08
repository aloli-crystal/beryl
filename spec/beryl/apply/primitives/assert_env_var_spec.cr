require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::AssertEnvVar do
  it "skip si la variable est posée et non vide" do
    ENV["BERYL_TEST_REASON"] = "valid reason"
    begin
      result = prim("assert-env-var").apply(
        FakeShell.new,
        apply_params(%({name: BERYL_TEST_REASON})),
        dry_run: false, context: ctx,
      )
      result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    ensure
      ENV.delete("BERYL_TEST_REASON")
    end
  end

  it "fail si la variable est absente" do
    ENV.delete("BERYL_TEST_MISSING")
    result = prim("assert-env-var").apply(
      FakeShell.new,
      apply_params(%({name: BERYL_TEST_MISSING})),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
    result.message.should contain("BERYL_TEST_MISSING")
  end

  it "fail si la variable est vide" do
    ENV["BERYL_TEST_EMPTY"] = ""
    begin
      result = prim("assert-env-var").apply(
        FakeShell.new,
        apply_params(%({name: BERYL_TEST_EMPTY})),
        dry_run: false, context: ctx,
      )
      result.outcome.should eq(Beryl::Apply::Outcome::Failed)
    ensure
      ENV.delete("BERYL_TEST_EMPTY")
    end
  end

  it "utilise le message personnalisé si fourni" do
    ENV.delete("BERYL_TEST_CUSTOM")
    result = prim("assert-env-var").apply(
      FakeShell.new,
      apply_params(%({name: BERYL_TEST_CUSTOM, message: "Refusé : raison obligatoire."})),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
    result.message.should eq("Refusé : raison obligatoire.")
  end
end
