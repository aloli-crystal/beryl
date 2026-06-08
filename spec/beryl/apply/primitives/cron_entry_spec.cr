require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

private ENTRY = "0 3 * * * /usr/sbin/freebsd-update cron"
private TAB   = "# >>> beryl >>>\n#{ENTRY}\n# <<< beryl <<<\n"

describe Beryl::Apply::CronEntry do
  it "ajoute une entrée et installe la crontab" do
    shell = FakeShell.new
    shell.stub(/crontab -l/, stdout: "")
    result = prim("cron-entry").apply(shell, apply_params({entry: ENTRY}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.writes.first.content.should contain(ENTRY)
    shell.ran?(/crontab -u root/).should be_true
  end

  it "skip si l'entrée est déjà présente" do
    shell = FakeShell.new
    shell.stub(/crontab -l/, stdout: TAB)
    result = prim("cron-entry").apply(shell, apply_params({entry: ENTRY}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.writes.should be_empty
  end

  it "retire une entrée existante (state: absent)" do
    shell = FakeShell.new
    shell.stub(/crontab -l/, stdout: TAB)
    result = prim("cron-entry").apply(shell, apply_params({entry: ENTRY, state: "absent"}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.writes.first.content.should_not contain(ENTRY)
  end

  it "préserve les entrées hors bloc beryl" do
    shell = FakeShell.new
    shell.stub(/crontab -l/, stdout: "MAILTO=root\n#{TAB}")
    result = prim("cron-entry").apply(shell, apply_params({entry: "@reboot /usr/local/bin/x", state: "present"}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.writes.first.content.should contain("MAILTO=root")
  end
end
