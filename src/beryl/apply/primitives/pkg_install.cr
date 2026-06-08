require "../primitive"

module Beryl::Apply
  # Primitive `pkg-install` : garantit que les packages listés sont
  # installés via `pkg install -y`.
  #
  # Idempotence : lecture de l'état réel (`pkg info`) avant action,
  # seul le delta manquant est installé. Si tout est déjà présent →
  # `skipped`. En `dry_run`, le delta est calculé mais rien n'est
  # installé.
  #
  # Step YAML :
  #
  #     - pkg-install:
  #         packages: [bash, git, curl]
  class PkgInstall < Primitive
    def name : String
      "pkg-install"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      packages = string_array(params, "packages")
      return StepResult.skipped("aucun package déclaré") if packages.empty?

      installed = installed_packages(shell)
      missing = packages.reject { |p| installed.includes?(p) }

      if missing.empty?
        return StepResult.skipped("#{packages.size} package(s) déjà installé(s)")
      end

      msg = "+#{missing.size} package(s) : #{missing.join(", ")}"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      shell.exec("pkg install -y #{missing.map { |p| Process.quote(p) }.join(" ")}")
      StepResult.applied(msg)
    end

    # Ensemble des noms de packages installés (sans la version). On lit
    # tout en une seule commande pour limiter les allers-retours SSH —
    # `pkg info -q` liste `<nom>-<version>`, on retire le suffixe de
    # version pour comparer par nom.
    private def installed_packages(shell : Shell) : Set(String)
      out = shell.exec(
        "pkg info -q 2>/dev/null | sed 's/-[0-9].*$//' | sort -u",
        raise_on_error: false,
      ).stdout
      out.lines.map(&.strip).reject(&.empty?).to_set
    end
  end

  Primitive.register(PkgInstall.new)
end
