require "../primitive"

module Beryl::Apply
  # Primitive `pkg-versioned` : installe un paquet FreeBSD versionné du type
  # `<base><NN>-<composant>` (mariadb, postgresql, mysql…). Idempotente.
  #
  #     - pkg-versioned:
  #         base: mariadb
  #         version: latest      # défaut ; ou un numéro FreeBSD : 114, 1011…
  #         only: server         # optionnel : `server` ou `client`
  #
  # Sans `only` → installe `server` ET `client`. `version: latest` (ou
  # absent) → résolu par la VRAIE version (`pkg rquery '%v %n' | sort -V`),
  # car l'encodage FreeBSD sans point piège un tri des noms (mariadb 10.11
  # = `1011` se classerait après 11.4 = `114`). Capacité ÉTROITE : installer
  # un paquet versionné, rien d'autre.
  class PkgVersioned < Primitive
    def name : String
      "pkg-versioned"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      base = required_string(params, "base")
      version = (string(params, "version") || "latest")
      version = "latest" if version.empty?
      only = string(params, "only").try(&.lchop(':')) # tolère `:server`

      components =
        case only
        when "server" then ["server"]
        when "client" then ["client"]
        else               ["server", "client"]
        end

      num =
        if version == "latest"
          resolved = resolve_latest(shell, base)
          return StepResult.failed("aucun paquet #{base}*-server dans le dépôt (réseau ? pkg update ?)") unless resolved
          resolved
        else
          version
        end

      packages = components.map { |c| "#{base}#{num}-#{c}" }
      missing = packages.reject { |p| shell.exec("pkg info -e #{Process.quote(p)}", raise_on_error: false).success? }
      return StepResult.skipped("#{packages.join(", ")} déjà installé(s)") if missing.empty?
      return StepResult.applied("installerait #{missing.join(", ")} (dry-run)") if dry_run

      shell.exec("pkg install -y #{missing.map { |p| Process.quote(p) }.join(" ")}")
      StepResult.applied("installé : #{missing.join(", ")}")
    end

    # Numéro de version (encodé FreeBSD) du `<base>NN-server` le plus récent
    # du dépôt, déterminé sur la VRAIE version (%v), pas le nom. nil si aucun.
    private def resolve_latest(shell : Shell, base : String) : String?
      line = shell.exec(
        "pkg rquery -U '%v %n' | awk '$2 ~ /^#{base}[0-9]+-server$/' | sort -V | tail -1",
        raise_on_error: false,
      ).stdout.strip
      return nil if line.empty?
      pkg_name = line.split(' ').last? || ""
      if m = pkg_name.match(/^#{Regex.escape(base)}(\d+)-server$/)
        m[1]
      end
    end
  end

  Primitive.register(PkgVersioned.new)
end
