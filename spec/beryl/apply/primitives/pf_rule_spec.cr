require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

private RULE  = "block in quick proto tcp to port 23"
private BLOCK = "ext_if = em0\n# >>> beryl >>>\n#{RULE}\n# <<< beryl <<<\n"

describe Beryl::Apply::PfRule do
  it "ajoute une règle, valide puis recharge pf" do
    shell = FakeShell.new
    shell.stub(/cat .*pf\.conf/, stdout: "ext_if = em0\n")
    result = prim("pf-rule").apply(shell, apply_params({rule: RULE}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.writes.first.content.should contain(RULE)
    shell.ran?(/pfctl -nf/).should be_true
    shell.ran?(/pfctl -f/).should be_true
  end

  it "skip si la règle est déjà présente" do
    shell = FakeShell.new
    shell.stub(/cat .*pf\.conf/, stdout: BLOCK)
    result = prim("pf-rule").apply(shell, apply_params({rule: RULE}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.writes.should be_empty
  end

  it "retire une règle existante (state: absent)" do
    shell = FakeShell.new
    shell.stub(/cat .*pf\.conf/, stdout: BLOCK)
    result = prim("pf-rule").apply(shell, apply_params({rule: RULE, state: "absent"}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.writes.first.content.should_not contain(RULE)
  end
end
