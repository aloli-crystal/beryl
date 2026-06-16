require "option_parser"
require "../providers/ovh"

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

      # Choix interactif du rôle bastion (écrit `bastion:` dans le host.yml).
      # Pas en mode --attach (action OVH délibérée) ni hors terminal.
      configure_bastion(root, host) if STDIN.tty? && !attach

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
        STDERR.puts "⚠ #{host.fqdn} : rattaché au vRack côté OVH, mais le host.yml n'a PAS de"
        STDERR.puts "  `vrack-interface` → pas d'IP privée tant qu'on ne l'ajoute pas. Dans"
        STDERR.puts "  #{short}.host.yml :"
        STDERR.puts "      apply_recipes:"
        STDERR.puts "        - vrack-interface: { ip: 192.168.42.N }"
        STDERR.puts "  puis : beryl apply #{host.fqdn}"
      end
    end

    # Chooser interactif du rôle bastion → écrit `bastion:` dans le host.yml.
    private def self.configure_bastion(root : Beryl::Config::Root, host : Beryl::Config::ResolvedHost) : Nil
      return if host.virtual
      bastions = bastion_hosts(root)
      STDERR.puts
      STDERR.puts "Rôle bastion de #{host.fqdn} (actuel : #{bastion_label(host)}) :"
      STDERR.puts "  1) ce host EST un bastion          → bastion: true"
      STDERR.puts "  2) joindre via un bastion existant → bastion: <nom>"
      STDERR.puts "  3) pas de bastion                  → bastion: false"
      STDERR.puts "  0) ne rien changer"
      STDERR.print "Choix [0] : "
      case (STDIN.gets || "").strip
      when "1" then write_bastion(host, "true")
      when "3" then write_bastion(host, "false")
      when "2" then choose_existing_bastion(host, bastions)
      else          log "rôle bastion inchangé."
      end
    end

    # Hosts marqués `bastion: true` (la liste des bastions), triés par nom.
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

    private def self.bastion_label(host : Beryl::Config::ResolvedHost) : String
      return "EST un bastion (bastion: true)" if host.bastion?
      if n = host.bastion_name
        return "via #{n}"
      end
      "aucun"
    end

    private def self.choose_existing_bastion(host : Beryl::Config::ResolvedHost, bastions : Array(Beryl::Config::ResolvedHost)) : Nil
      if bastions.empty?
        log "aucun host marqué `bastion: true` — marquez-en un d'abord (choix 1 sur un z)."
        return
      end
      STDERR.puts "  Bastions disponibles :"
      bastions.each_with_index { |b, i| STDERR.puts "    #{i + 1}) #{b.short_name}  (#{b.fqdn})" }
      STDERR.print "  Lequel ? : "
      sel = (STDIN.gets || "").strip.to_i?
      if sel && (1..bastions.size).includes?(sel)
        write_bastion(host, bastions[sel - 1].short_name)
      else
        log "choix invalide — rien changé."
      end
    end

    # Pose/maj la clé top-level `bastion:` dans le host.yml (préserve le reste).
    private def self.write_bastion(host : Beryl::Config::ResolvedHost, value : String) : Nil
      path = host.node.source_path
      lines = File.read(path).split('\n')
      line = "bastion: #{value}"
      if idx = lines.index(&.starts_with?("bastion:"))
        lines[idx] = line
      elsif ar = lines.index(&.starts_with?("apply_recipes:"))
        lines.insert(ar, line)
      else
        lines << line
      end
      File.write(path, lines.join('\n'))
      log "#{host.fqdn} : #{line} (écrit dans #{File.basename(path)})"
    end

    private def self.log(message : String) : Nil
      STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl vrack] #{message}"
    end
  end
end
