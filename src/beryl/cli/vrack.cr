require "option_parser"
require "../providers/ovh"
require "../apply"

module Beryl::CLI
  # `beryl vrack <host> [--attach]` : interroge l'API OVH pour savoir si le
  # serveur d'un host est dans un vRack, et le rattache avec `--attach`.
  #
  #   beryl vrack han.quimeo.net              # statut seulement
  #   beryl vrack han.quimeo.net --attach     # rattache (task async + suivi)
  #   beryl vrack han.quimeo.net --attach --vrack pn-12345
  module Vrack
    EXIT_OK         = 0
    EXIT_USAGE      = 1
    EXIT_FAIL       = 2
    EXIT_UNEXPECTED = 3

    POLL_INTERVAL = 5.seconds
    POLL_MAX      = 36 # ~3 min

    def self.run(config_root : String, args : Array(String)) : Int32
      attach = false
      forced_vrack : String? = nil
      account_hint : String? = nil
      domain_hint : String? = nil
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "USAGE : beryl vrack <host> [--attach] [--vrack pn-XXXX]"
        p.on("--attach", "Rattache le serveur au vRack s'il ne l'est pas (task async)") { attach = true }
        p.on("--vrack NAME", "Forcer le vRack cible si le compte en a plusieurs") { |v| forced_vrack = v }
        p.on("-a NAME", "--account=NAME", "Forcer la société") { |v| account_hint = v }
        p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
        p.on("-h", "--help", "Aide") { puts p; exit 0 }
        p.unknown_args { |rest, _| positional = rest }
      end
      parser.parse(args)

      raw = positional.first?
      unless raw
        STDERR.puts "beryl : host non précisé. USAGE : beryl vrack <host> [--attach]"
        return EXIT_USAGE
      end
      parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
      account_hint ||= parsed[:account]
      domain_hint ||= parsed[:domain]

      root = Beryl::Config::Root.load(config_root)
      host = root.resolve(parsed[:host], account_hint: account_hint, domain_hint: domain_hint)
      host.apply_all_credentials_to_env!

      service = host.ovh_service_name
      unless service
        STDERR.puts "beryl : pas de `ovh.service_name` pour #{host.fqdn} (provider ovh ?)."
        return EXIT_USAGE
      end

      provider = Beryl::Providers::Ovh.new
      unless provider.available?
        STDERR.puts "beryl : credentials OVH absents pour #{host.account_name} (cf. les credentials de la société)."
        return EXIT_USAGE
      end

      log "host #{host.fqdn} → service OVH #{service}"

      current = provider.vrack_of_server(service)
      if current
        log "✅ #{service} est DÉJÀ dans le vRack #{current}."
        finalize_network(root, host) unless attach
        warn_if_no_vrack_ip(host)
        return EXIT_OK
      end

      vracks = provider.list_vracks
      if vracks.empty?
        STDERR.puts "beryl : aucun vRack sur le compte. Commandez-en un dans le manager OVH (gratuit)."
        return EXIT_FAIL
      end
      log "#{service} dans aucun vRack. vRack(s) du compte : #{vracks.join(", ")}"

      unless attach
        hint = vracks.size > 1 ? " --vrack <pn-...>" : ""
        log "pour rattacher : beryl vrack #{raw} --attach#{hint}"
        return EXIT_OK
      end

      target = forced_vrack || (vracks.size == 1 ? vracks.first : nil)
      unless target
        STDERR.puts "beryl : plusieurs vRacks (#{vracks.join(", ")}) — précisez --vrack <pn-...>."
        return EXIT_USAGE
      end

      log "rattachement de #{service} au vRack #{target}…"
      task_id = provider.attach_dedicated_server(target, service)
      if task_id.empty?
        STDERR.puts "beryl : pas d'id de task retourné par l'API."
        return EXIT_FAIL
      end
      log "task #{task_id} créée — suivi (1-2 min)…"

      POLL_MAX.times do
        sleep POLL_INTERVAL
        status = provider.vrack_task_status(target, task_id)
        # nil = task purgée par OVH une fois terminée → on considère OK.
        if status.nil? || status == "done"
          log "✅ #{service} rattaché au vRack #{target}. L'interface privée (ix1) montera dans quelques minutes."
          log "ℹ le rattachement peut REDÉMARRER le serveur → si vous enchaînez un bootstrap, re-lancez d'abord `beryl rescue #{host.fqdn}`."
          warn_if_no_vrack_ip(host)
          return EXIT_OK
        end
        log "  task #{task_id} : #{status}"
        if status == "error" || status == "cancelled"
          STDERR.puts "beryl : la task de rattachement a échoué (#{status})."
          return EXIT_FAIL
        end
      end
      log "task #{task_id} toujours en cours après #{(POLL_INTERVAL * POLL_MAX).total_seconds.to_i}s — vérifiez le manager OVH."
      EXIT_OK
    rescue ex
      STDERR.puts "beryl : erreur vrack — #{ex.class}: #{ex.message}"
      STDERR.puts "  (refus d'accès /vrack ? Ré-autorisez la clé OVH : les droits ont changé, regénérez les credentials.)"
      EXIT_UNEXPECTED
    end

    # Rattacher côté OVH ne suffit pas : sans `vrack-interface` dans le
    # host.yml, le serveur n'a pas d'IP privée. On le vérifie et on rappelle
    # quoi ajouter (l'IP vient de ResolvedHost#vrack_ip).
    private def self.warn_if_no_vrack_ip(host : Beryl::Config::ResolvedHost) : Nil
      if ip = host.vrack_ip
        log "config OK : #{host.fqdn} déclare une IP vRack (#{ip})."
      else
        short = host.fqdn.split('.').first
        STDERR.puts
        STDERR.puts "⚠ #{host.fqdn} : rattaché au vRack côté OVH, mais le host.yml n'a PAS"
        STDERR.puts "  d'IP vRack → pas d'IP privée tant qu'on ne la déclare pas. Dans"
        STDERR.puts "  #{short}.host.yml :"
        STDERR.puts "      network:"
        STDERR.puts "        vrack_ip: 192.168.42.N"
        STDERR.puts "  puis : beryl vrack #{host.fqdn}"
      end
    end

    # Host confirmé dans le vRack : monte la 1ʳᵉ IP (netif) PUIS propose le
    # chooser réseau (TTY). Best-effort sur le netif (logue, n'avorte pas).
    private def self.finalize_network(root : Beryl::Config::Root, host : Beryl::Config::ResolvedHost) : Nil
      if ip = host.vrack_ips.first?
        mount_primary_vrack_ip(host)
        # Consolide l'IP dans la section network: (depuis le legacy
        # vrack-interface au besoin) → bloc network: complet. On NE touche
        # PAS si network.vrack_ip est déjà déclaré (peut être une LISTE).
        write_network(host, "vrack_ip", ip) unless host.network_declares_vrack_ip?
      end
      configure_network(root, host) if STDIN.tty?
    end

    # Chooser interactif du rôle RÉSEAU → écrit `network:` dans le host.yml.
    private def self.configure_network(root : Beryl::Config::Root, host : Beryl::Config::ResolvedHost) : Nil
      return if host.virtual
      bastions = bastion_hosts(root)
      STDERR.puts
      STDERR.puts "Rôle réseau de #{host.fqdn} (actuel : #{network_label(host)}) :"
      STDERR.puts "  1) ce host EST un bastion          → network.bastion: true"
      STDERR.puts "  2) joindre via un bastion          → network.proxy_jump"
      STDERR.puts "  3) pas de bastion (public)         → network.bastion: false"
      STDERR.puts "  0) ne rien changer"
      STDERR.print "Choix [0] : "
      case (STDIN.gets || "").strip
      when "1"
        write_network(host, "bastion", "true")
        write_network_remove(host, "proxy_jump") # un bastion n'a pas de proxy_jump
      when "3"
        write_network(host, "bastion", "false")
        write_network_remove(host, "proxy_jump")
      when "2"
        choose_via_bastion(host, bastions)
      else
        log "rôle réseau inchangé."
      end
    end

    # Hosts marqués bastion (`network.bastion: true` ou legacy), triés par nom.
    private def self.bastion_hosts(root : Beryl::Config::Root) : Array(Beryl::Config::ResolvedHost)
      root.all_hosts_by_fqdn.keys.compact_map do |fqdn|
        h = begin
          root.resolve(fqdn)
        rescue
          next
        end
        h.bastion? ? h : nil
      end.sort_by(&.fqdn)
    end

    private def self.network_label(host : Beryl::Config::ResolvedHost) : String
      return "EST un bastion" if host.bastion?
      if pj = host.proxy_jump(connect_user(host))
        return "caché via #{pj}"
      end
      "aucun / public"
    end

    private def self.choose_via_bastion(host : Beryl::Config::ResolvedHost, bastions : Array(Beryl::Config::ResolvedHost)) : Nil
      if bastions.empty?
        log "aucun host `network.bastion: true` — marquez-en un d'abord (choix 1 sur un z)."
        return
      end
      STDERR.puts "  Bastions disponibles :"
      bastions.each_with_index { |b, i| STDERR.puts "    #{i + 1}) #{b.short_name}  (#{b.fqdn})" }
      STDERR.print "  Lequel ? : "
      sel = (STDIN.gets || "").strip.to_i?
      unless sel && (1..bastions.size).includes?(sel)
        log "choix invalide — rien changé."
        return
      end
      bastion = bastions[sel - 1]
      pj = derive_proxy_jump(connect_user(host), bastion.short_name, host.domain_name)
      # Garde-fou §6 : on VÉRIFIE le chemin caché AVANT d'écrire proxy_jump.
      log "vérification du chemin caché : ssh #{pj} → #{host.vrack_ips.first?} → uname…"
      unless verify_via_bastion(host, pj)
        log "✗ #{host.fqdn} injoignable par #{pj}. L'IP vRack est-elle montée et le bastion OK ?"
        log "  proxy_jump NON écrit (rien changé)."
        return
      end
      write_network(host, "proxy_jump", pj)
      log "✓ chemin vérifié — proxy_jump posé."
      offer_close_22(host, pj)
    end

    # Pose/maj `network.<key>: value` dans le host.yml (préserve le reste).
    private def self.write_network(host : Beryl::Config::ResolvedHost, key : String, value : String) : Nil
      path = host.node.source_path
      File.write(path, upsert_network_field(File.read(path), key, value))
      log "#{host.fqdn} : network.#{key}: #{value} (#{File.basename(path)})"
    end

    # Retire `network.<key>` du host.yml (no-op si absent).
    private def self.write_network_remove(host : Beryl::Config::ResolvedHost, key : String) : Nil
      path = host.node.source_path
      before = File.read(path)
      after = remove_network_field(before, key)
      return if before == after
      File.write(path, after)
      log "#{host.fqdn} : network.#{key} retiré (#{File.basename(path)})"
    end

    # ─────────────────────────────────────────────────────────────
    # Écriture du bloc `network:` du host.yml (fonctions PURES sur le
    # contenu — testables sans SSH ni I/O). `beryl vrack` est la SEULE
    # porte qui pose `network.proxy_jump`/`network.bastion` (spec §6).
    # ─────────────────────────────────────────────────────────────

    # Pose/maj `key: value` dans le bloc `network:` (indenté 2 espaces),
    # en préservant le reste. Crée le bloc `network:` s'il est absent (avant
    # `apply_recipes:` si présent, sinon en fin). Retourne le nouveau contenu.
    def self.upsert_network_field(content : String, key : String, value : String) : String
      lines = content.split('\n')
      field = "  #{key}: #{value}"
      if net = lines.index { |l| l.rstrip == "network:" }
        i = net + 1
        while i < lines.size && lines[i].starts_with?("  ")
          if lines[i].lstrip.starts_with?("#{key}:")
            lines[i] = field
            return lines.join('\n')
          end
          i += 1
        end
        lines.insert(i, field) # fin du bloc network:
        return lines.join('\n')
      end
      if ar = lines.index { |l| l.starts_with?("apply_recipes:") }
        lines.insert(ar, "network:")
        lines.insert(ar + 1, field)
      else
        # Insérer AVANT d'éventuelles lignes vides finales (le `\n` terminal du
        # fichier) pour ne pas créer de ligne blanche parasite.
        pos = lines.size
        while pos > 0 && lines[pos - 1].empty?
          pos -= 1
        end
        lines.insert(pos, field)
        lines.insert(pos, "network:")
      end
      lines.join('\n')
    end

    # Retire `key:` du bloc `network:` (et le bloc s'il devient vide).
    # No-op si absent. Retourne le nouveau contenu.
    def self.remove_network_field(content : String, key : String) : String
      lines = content.split('\n')
      net = lines.index { |l| l.rstrip == "network:" }
      return content unless net
      i = net + 1
      while i < lines.size && lines[i].starts_with?("  ")
        if lines[i].lstrip.starts_with?("#{key}:")
          lines.delete_at(i)
          # Bloc network: vide (plus d'enfant indenté juste après) → on le retire.
          if net + 1 >= lines.size || !lines[net + 1].starts_with?("  ")
            lines.delete_at(net)
          end
          return lines.join('\n')
        end
        i += 1
      end
      content
    end

    # ─────────────────────────────────────────────────────────────
    # Orchestration serveur (SSH). PARTIES SÛRES seulement : monter l'IP
    # (netif) et VÉRIFIER le chemin caché. AUCUNE fermeture du 22 ici → le
    # lockout est impossible. La phase pf (fermeture du 22) viendra à part,
    # avec validation in-vivo.
    # ⚠ Ces helpers exécutent du SSH réel → à valider sur un host de test.
    # ─────────────────────────────────────────────────────────────

    # User de connexion SSH : le PREMIER user sudo-capable de `freebsd.users`
    # (le SSH root est coupé sur les hôtes durcis), à défaut `host.user`.
    # Aligné sur `beryl apply` (sinon on tenterait `root` → injoignable).
    private def self.connect_user(host : Beryl::Config::ResolvedHost) : String
      freebsd = host.merged[YAML::Any.new("freebsd")]?.try(&.as_h?)
      if freebsd && (users = freebsd[YAML::Any.new("users")]?.try(&.as_a?))
        users.each do |u|
          uh = u.as_h?
          next unless uh
          name = uh[YAML::Any.new("name")]?.try(&.as_s?)
          next unless name
          wheel = uh[YAML::Any.new("groups")]?.try(&.as_a?).try(&.any? { |g| g.as_s? == "wheel" }) || false
          sudo = uh[YAML::Any.new("sudo")]?.try(&.as_bool?) == true
          return name if wheel || sudo
        end
      end
      host.user
    end

    # Connexion sudo-capable vers le host (même logique que `beryl apply` :
    # user sudo-capable, escalade SudoShell si non-root). nil si injoignable / sudo KO.
    private def self.network_shell(host : Beryl::Config::ResolvedHost) : Beryl::Apply::Shell?
      cu = connect_user(host)
      conn = host.connection(cu)
      uname = conn.exec("uname -s", raise_on_error: false).stdout.strip
      unless uname == "FreeBSD"
        log "✗ #{host.fqdn} injoignable ou pas FreeBSD (uname = #{uname.inspect})."
        return nil
      end
      return Beryl::Apply::SshShell.new(conn) if cu == "root"
      unless conn.exec("sudo -n true", raise_on_error: false).success?
        log "✗ #{cu}@#{host.fqdn} ne peut pas sudo sans mot de passe."
        return nil
      end
      Beryl::Apply::SudoShell.new(Beryl::Apply::SshShell.new(conn))
    end

    # Monte la 1ʳᵉ IP vRack sur l'interface (primitive `netif`, idempotente,
    # persistante). SÛR : ajoute une IP, ne ferme rien. true si OK.
    private def self.mount_primary_vrack_ip(host : Beryl::Config::ResolvedHost) : Bool
      ip = host.vrack_ips.first?
      return false unless ip
      shell = network_shell(host)
      return false unless shell
      params = {"iface" => YAML::Any.new("auto"), "ip" => YAML::Any.new(ip)}
      result = Beryl::Apply::Primitive["netif"]?.not_nil!.apply(
        shell, params, false, Beryl::Apply::Context.new)
      log "netif #{ip} : #{result.outcome} — #{result.message}"
      !result.outcome.failed?
    end

    # Vérifie le chemin CACHÉ : `ssh <proxy_jump> → vrack_ip[0] → uname`.
    # Lecture seule (aucune écriture). true si le host répond FreeBSD par le
    # bastion. C'est le garde-fou avant d'écrire `proxy_jump` (spec §6).
    private def self.verify_via_bastion(host : Beryl::Config::ResolvedHost, proxy_jump : String) : Bool
      ip = host.vrack_ips.first?
      return false unless ip
      conn = SSH::Connection.new(
        host: ip,
        user: connect_user(host),
        port: host.port,
        identity_file: host.identity_file,
        options: {"ProxyJump" => proxy_jump},
      )
      conn.exec("uname -s", raise_on_error: false).stdout.strip == "FreeBSD"
    end

    # Shell sudo-capable connecté EXPLICITEMENT par le bastion (host = vrack_ip,
    # ProxyJump = pj). C'est le chemin vRack → fermer le 22 PUBLIC via ce shell
    # ne coupe PAS la session (anti-lockout, spec §4). nil si injoignable / sudo KO.
    private def self.bastion_shell(host : Beryl::Config::ResolvedHost, pj : String) : Beryl::Apply::Shell?
      ip = host.vrack_ips.first?
      return nil unless ip
      cu = connect_user(host)
      conn = SSH::Connection.new(
        host: ip, user: cu, port: host.port,
        identity_file: host.identity_file, options: {"ProxyJump" => pj},
      )
      return nil unless conn.exec("uname -s", raise_on_error: false).stdout.strip == "FreeBSD"
      return Beryl::Apply::SshShell.new(conn) if cu == "root"
      return nil unless conn.exec("sudo -n true", raise_on_error: false).success?
      Beryl::Apply::SudoShell.new(Beryl::Apply::SshShell.new(conn))
    end

    # Ferme le 22 PUBLIC (pf), avec FILET anti-lockout. À n'appeler qu'après que
    # `proxy_jump` est VÉRIFIÉ. Séquence sûre :
    #   1. (re)connexion PAR LE BASTION (vRack) → fermer le 22 public ne coupe pas ;
    #   2. dead-man switch : dans 120s, `pfctl -d` (rollback) SAUF si flag de commit ;
    #   3. pose des règles pf éprouvées (= recette sshd-vrack-only) + recharge ;
    #   4. re-vérif joignabilité par le bastion → commit (touch flag) ou rollback.
    private def self.close_public_22(host : Beryl::Config::ResolvedHost, pj : String) : Bool
      ip = host.vrack_ips.first?
      return false unless ip
      shell = bastion_shell(host, pj)
      unless shell
        log "✗ injoignable PAR LE BASTION — on ne ferme PAS le 22 (anti-lockout)."
        return false
      end
      subnet = derive_subnet(ip)
      # `flags any` sur le pass : laisse passer les paquets MID-STREAM (pas que
      # les SYN) → la connexion DÉJÀ établie (par le bastion) survit au reload pf
      # (sinon ses paquets non-SYN sont jetés → blocage ~120s → faux lockout).
      pfconf = "# Généré par beryl vrack — NE PAS éditer à la main.\n" \
               "set skip on lo\n" \
               "pass in quick inet proto tcp from #{subnet} to port 22 flags any\n" \
               "block in quick proto tcp to port 22\n"

      shell.exec("rm -f /tmp/beryl-pf-committed", raise_on_error: false)
      # `daemon -f` détache PROPREMENT (session propre, fds → /dev/null) → ne
      # bloque pas la connexion SSH multiplexée (contrairement à `nohup … &`).
      shell.exec(
        "daemon -f /bin/sh -c 'sleep 120; [ -f /tmp/beryl-pf-committed ] || pfctl -d'",
        raise_on_error: false)
      log "filet dead-man armé : pf se DÉSACTIVE dans 120s si on perd la main."

      log "→ écriture /etc/pf.conf…"
      shell.write_file("/etc/pf.conf", pfconf, mode: "0644")
      log "→ sysrc pf_enable=YES…"
      shell.exec("sysrc pf_enable=YES", raise_on_error: false)
      log "→ pfctl -f (charge les règles)…"
      shell.exec("pfctl -f /etc/pf.conf", raise_on_error: false)
      log "→ pfctl -e (active pf, idempotent)…"
      shell.exec("pfctl -e", raise_on_error: false)
      log "pf chargé : 22 PUBLIC bloqué, vRack #{subnet} autorisé."

      # Vérif via la connexion EXISTANTE (`shell`, déjà établie par le bastion,
      # état gardé par pf) : si MA session a survécu à la fermeture, on n'est pas
      # lockout. On NE rouvre PAS de connexion neuve (son SYN se ferait jeter
      # brièvement après le reload pf → ~120s de retransmission TCP).
      if shell.exec("uname -s", raise_on_error: false).stdout.strip == "FreeBSD"
        shell.exec("touch /tmp/beryl-pf-committed", raise_on_error: false) # commit
        log "✓ session toujours vivante après fermeture → 22 public FERMÉ (commité, dead-man annulé)."
        true
      else
        log "✗ session COUPÉE après fermeture → le dead-man va ROLLBACK (pfctl -d) sous 120s."
        log "  rien commité ; vérifiez la config réseau puis recommencez."
        false
      end
    end

    # Dérive la chaîne `proxy_jump` `<user>@<bastion-fqdn>` depuis le nom (court
    # OU FQDN) du bastion et le domaine du host caché. Pur.
    def self.derive_proxy_jump(connect_user : String, bastion : String, domain : String) : String
      host = bastion.includes?('.') ? bastion : "#{bastion}.#{domain}"
      "#{connect_user}@#{host}"
    end

    # Dérive le /24 d'une IP (ex. 192.168.42.31 → 192.168.42.0/24). Pur.
    def self.derive_subnet(ip : String) : String
      p = ip.split('.')
      return ip unless p.size == 4
      "#{p[0]}.#{p[1]}.#{p[2]}.0/24"
    end

    # Propose (TTY) de fermer le 22 PUBLIC maintenant. Défaut = NON (sûr).
    private def self.offer_close_22(host : Beryl::Config::ResolvedHost, pj : String) : Nil
      STDERR.print "Fermer le port 22 PUBLIC maintenant (pf, filet anti-lockout) ? [o/N] : "
      unless (STDIN.gets || "").strip.downcase == "o"
        log "22 public laissé OUVERT — relancez `beryl vrack` pour fermer plus tard."
        return
      end
      close_public_22(host, pj)
    end

    private def self.log(message : String) : Nil
      STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl vrack] #{message}"
    end
  end
end
