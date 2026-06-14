require "../primitive"

module Beryl::Apply
  # Primitive `group-member` : garantit qu'un utilisateur EXISTANT est
  # membre d'un groupe, via `pw groupmod <group> -m <user>`. Idempotent :
  # skip s'il est déjà membre, skip si le user ou le groupe est absent.
  # Capacité ÉTROITE : AJOUTE une appartenance, n'en retire jamais
  # (`-m` fusionne, ne remplace pas — contrairement à `usermod -G`).
  #
  # Cas d'usage : le démon `clamd` tourne sous l'utilisateur `clamav` et
  # doit pouvoir `chgrp` son socket vers `www` → `clamav` doit être membre
  # de `www` (un process non-root ne peut chgrp que vers un groupe dont il
  # est membre).
  #
  #     - group-member:
  #         user: clamav
  #         group: www
  class GroupMember < Primitive
    def name : String
      "group-member"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      user = required_string(params, "user")
      group = required_string(params, "group")

      passwd = shell.exec("getent passwd #{Process.quote(user)} 2>/dev/null", raise_on_error: false).stdout.strip
      return StepResult.skipped("user #{user} absent (créez-le d'abord)") if passwd.empty?

      grp = shell.exec("getent group #{Process.quote(group)} 2>/dev/null", raise_on_error: false).stdout.strip
      return StepResult.skipped("groupe #{group} absent") if grp.empty?

      # Groupes effectifs du user (primaire + secondaires).
      current = shell.exec("id -Gn #{Process.quote(user)} 2>/dev/null", raise_on_error: false).stdout.split(/\s+/)
      return StepResult.skipped("#{user} déjà membre de #{group}") if current.includes?(group)
      return StepResult.applied("#{user} → groupe #{group} (dry-run)") if dry_run

      res = shell.exec("pw groupmod #{Process.quote(group)} -m #{Process.quote(user)}", raise_on_error: false)
      return StepResult.failed("pw groupmod #{group} -m #{user} : #{res.stderr.strip}") unless res.success?
      StepResult.applied("#{user} ajouté au groupe #{group}")
    end
  end

  Primitive.register(GroupMember.new)
end
