require "../primitive"

module Beryl::Apply
  # Primitive `sshd-config-set` : pose une directive dans
  # `/etc/ssh/sshd_config.d/beryl.conf` (fichier géré par beryl, inclus
  # par le `sshd_config` de base via `Include sshd_config.d/*.conf`).
  #
  # Idempotence : la directive est déjà présente avec la bonne valeur →
  # skip. Sinon le fichier est réécrit, validé (`sshd -t`) et sshd est
  # rechargé (`service sshd reload`).
  #
  #     - sshd-config-set:
  #         key: PermitRootLogin
  #         value: "no"
  #
  # Cas où la valeur dépend d'un état runtime (ex. IP de l'interface
  # tailscale0 inconnue à l'écriture de la recette) : utiliser
  # `value_from_command` à la place. La commande est exécutée côté
  # serveur cible, son stdout strippé devient la valeur. Échec
  # (exit ≠ 0 ou stdout vide) → la primitive `fail`.
  #
  #     - sshd-config-set:
  #         key: ListenAddress
  #         value_from_command: "tailscale ip -4"
  class SshdConfigSet < Primitive
    PATH = "/etc/ssh/sshd_config.d/beryl.conf"

    HEADER = "# Géré par beryl (sshd-config-set). Ne pas éditer à la main.\n"

    def name : String
      "sshd-config-set"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      key = required_string(params, "key")

      static_value = string(params, "value")
      cmd_value = string(params, "value_from_command")

      if static_value.nil? && cmd_value.nil?
        return StepResult.failed("ni `value` ni `value_from_command` fournis")
      end
      if static_value && cmd_value
        return StepResult.failed("`value` et `value_from_command` sont mutuellement exclusifs")
      end

      value = if cmd = cmd_value
                probe = shell.exec(cmd, raise_on_error: false)
                resolved = probe.stdout.strip
                if !probe.success? || resolved.empty?
                  return StepResult.failed("`value_from_command` (#{cmd}) retourne vide ou échoue : #{probe.stderr.strip}")
                end
                resolved
              else
                static_value.not_nil!
              end

      directives = parse(shell.exec("cat #{Process.quote(PATH)} 2>/dev/null", raise_on_error: false).stdout)

      if directives[key]? == value
        return StepResult.skipped("#{key} déjà = #{value}")
      end

      previous = directives[key]?
      directives[key] = value
      msg = "#{key} : #{previous.nil? ? "(absent)" : previous} → #{value}"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      shell.exec("mkdir -p #{Process.quote(File.dirname(PATH))}")
      shell.write_file(PATH, render(directives), mode: "0644")
      shell.exec("sshd -t") # valide la conf — échec = stop net
      shell.exec("service sshd reload")
      StepResult.applied(msg)
    end

    # Parse le fichier géré (lignes `Clé Valeur`) en préservant l'ordre
    # d'apparition. Ignore commentaires et lignes vides.
    private def parse(content : String) : Hash(String, String)
      result = {} of String => String
      content.each_line do |raw|
        line = raw.strip
        next if line.empty? || line.starts_with?('#')
        parts = line.split(/\s+/, 2)
        next unless parts.size == 2
        result[parts[0]] = parts[1]
      end
      result
    end

    private def render(directives : Hash(String, String)) : String
      String.build do |io|
        io << HEADER
        directives.each { |k, v| io << k << ' ' << v << '\n' }
      end
    end
  end

  Primitive.register(SshdConfigSet.new)
end
