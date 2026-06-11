require "../primitive"

module Beryl::Apply
  # Primitive `user-sync` : réconcilie UN compte depuis sa déclaration
  # `freebsd.users`. Idempotente.
  #
  #     - user-sync:
  #         name: deploy
  #         secondary_groups: [www, wheel]
  #         shell: /usr/local/bin/zsh   # optionnel
  #         primary_group: www          # optionnel (création seule)
  #         state: present              # ou `absent` → pw userdel
  #
  # Groupes ADDITIFS (`secondary_groups` ou alias `groups`) : on ajoute le
  # user aux groupes listés (s'il n'y est pas), on n'en retire JAMAIS —
  # modèle « héritage » (on ajoute ce dont on a besoin). Le `shell` n'est
  # posé qu'à la CRÉATION : sur un user existant, le changement de shell
  # passe par une recette (oh-my-zsh / user-shell) — sinon il entrerait en
  # conflit avec ces recettes (flap csh↔zsh à chaque apply). La suppression
  # exige `state: absent` EXPLICITE (jamais par absence) et garde le /home.
  class UserSync < Primitive
    def name : String
      "user-sync"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      user = required_string(params, "name")
      state = string(params, "state") || "present"
      line = shell.exec("getent passwd #{Process.quote(user)} 2>/dev/null", raise_on_error: false).stdout.strip
      exists = !line.empty?

      if state == "absent"
        return StepResult.skipped("#{user} déjà absent") unless exists
        return StepResult.applied("#{user} : compte supprimé (dry-run)") if dry_run
        shell.exec("pw userdel #{Process.quote(user)}") # /home conservé (pas de -r)
        return StepResult.applied("#{user} : compte supprimé (home conservé)")
      end

      # `secondary_groups` (canonique, comme le bootstrap) + alias `groups`.
      groups = (string_array(params, "secondary_groups") + string_array(params, "groups")).uniq
      shell_path = string(params, "shell")
      primary = string(params, "primary_group")

      unless exists
        return StepResult.applied("#{user} : à créer (dry-run)") if dry_run
        args = ["useradd", "-n", user, "-m"]
        args.concat(["-g", primary]) if primary
        args.concat(["-G", groups.join(",")]) unless groups.empty?
        args.concat(["-s", shell_path]) if shell_path
        shell.exec("pw #{args.map { |a| Process.quote(a) }.join(" ")}")
        return StepResult.applied("#{user} : créé")
      end

      # Compte existant → réconciliation ADDITIVE.
      changes = [] of String
      current_groups = shell.exec("id -Gn #{Process.quote(user)} 2>/dev/null", raise_on_error: false).stdout.split
      groups.each do |g|
        next if current_groups.includes?(g)
        shell.exec("pw groupmod #{Process.quote(g)} -m #{Process.quote(user)}") unless dry_run
        changes << "+#{g}"
      end

      # Le shell d'un user EXISTANT n'est pas touché ici (cf. en-tête) :
      # une recette s'en charge (oh-my-zsh / user-shell), sans flap.

      return StepResult.skipped("#{user} : conforme") if changes.empty?
      msg = "#{user} : #{changes.join(", ")}"
      StepResult.applied(dry_run ? "#{msg} (dry-run)" : msg)
    end
  end

  Primitive.register(UserSync.new)
end
