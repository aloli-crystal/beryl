require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::MakeInstall do
  it "skip si `creates` existe déjà (idempotent)" do
    shell = FakeShell.new
    shell.stub(/test -e/, exit_code: 0) # déjà présent
    result = prim("make-install").apply(
      shell, apply_params(%({url: "https://x/c.tgz", creates: /usr/local/share/chruby/chruby.sh})), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/make install/).should be_false
  end

  it "fetch + make install si absent" do
    shell = FakeShell.new
    shell.stub(/test -e/, exit_code: 1) # absent
    result = prim("make-install").apply(
      shell, apply_params(%({url: "https://x/c.tgz", creates: /opt/c})), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/fetch -q -o/).should be_true
    shell.ran?(%r{make install PREFIX=/usr/local}).should be_true
  end

  it "insère la vérification sha256 si fournie" do
    shell = FakeShell.new
    shell.stub(/test -e/, exit_code: 1)
    prim("make-install").apply(
      shell, apply_params(%({url: "https://x/c.tgz", sha256: deadbeef})), dry_run: false, context: ctx)
    shell.ran?(/sha256 -q.*deadbeef/).should be_true
  end
end
