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

    private def self.log(message : String) : Nil
      STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl vrack] #{message}"
    end
  end
end
