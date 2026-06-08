require "../primitive"

module Beryl::Apply
  # Primitive `pkg-remove` : garantit que les packages listés sont
  # absents via `pkg delete -y`.
  #
  # Idempotence : lecture de `pkg info` avant action, seuls les
  # packages réellement présents sont supprimés. Si aucun n'est
  # installé → `skipped`.
  #
  # Step YAML :
  #
  #     - pkg-remove:
  #         packages: [sendmail, telnet]
  class PkgRemove < Primitive
    def name : String
      "pkg-remove"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      packages = string_array(params, "packages")
      return StepResult.skipped("aucun package déclaré") if packages.empty?

      installed = installed_packages(shell)
      present = packages.select { |p| installed.includes?(p) }

      if present.empty?
        return StepResult.skipped("#{packages.size} package(s) déjà absent(s)")
      end

      msg = "-#{present.size} package(s) : #{present.join(", ")}"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      shell.exec("pkg delete -y #{present.map { |p| Process.quote(p) }.join(" ")}")
      StepResult.applied(msg)
    end

    private def installed_packages(shell : Shell) : Set(String)
      shell.exec(
        "pkg info -q 2>/dev/null | sed 's/-[0-9].*$//' | sort -u",
        raise_on_error: false,
      ).stdout.lines.map(&.strip).reject(&.empty?).to_set
    end
  end

  Primitive.register(PkgRemove.new)
end
