require "option_parser"
require "./credentials"
require "./dns_setup"
require "./account_utils"

module Beryl::CLI
  # `beryl dns <host>` — pose / resynchronise les enregistrements DNS d'un
  # host DÉJÀ déclaré, indépendamment du scan. À lancer quand on a oublié
  # `scan --dns`, après un changement d'IP, ou pour reposer un reverse.
  #
  # MULTI-PROVIDER (ADR-014) — découple le DNS du compute :
  #   - forward A/AAAA  → via le **dns_provider** de la zone
  #     (`host.dns_provider`, ex. gandi) : `ensure_record` + `refresh_zone`.
  #   - reverse PTR     → via le **compute provider** propriétaire de l'IP
  #     (`host.provider`, ex. ovh) : `set_reverse` (Gandi ne sait pas).
  #   - rename panel    → via le compute provider (OVH displayName).
  #
  # La détection d'IP est compute-spécifique : OVH câblé (dédiés). Les
  # autres providers compute (scaleway/dedibox) suivront — refus explicite
  # d'ici là (règle Aloli : pas d'échec silencieux).
  module Dns
    EXIT_OK      =  0
    EXIT_USAGE   =  2
    EXIT_ABORTED =  6
    EXIT_RUNTIME = 10

    def self.run(config_root : String, args : Array(String)) : Int32
      dry_run = false
      non_interactive = false
      hostname_flag : String? = nil
      zone_flag : String? = nil
      account_hint : String? = nil
      domain_hint : String? = nil
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: beryl dns <host> [options]\n\n" \
                   "Pose les records DNS d'un host : forward (A/AAAA) via le dns_provider\n" \
                   "de la zone, reverse (PTR) + rename via le compute provider."
        p.on("-n", "--dry-run", "Affiche le plan sans appel API") { dry_run = true }
        p.on("-H NAME", "--hostname=NAME", "Nom court (défaut : nom du host)") { |v| hostname_flag = v }
        p.on("-z ZONE", "--zone=ZONE", "Zone DNS (défaut : le domaine du host)") { |v| zone_flag = v }
        p.on("-a ACCOUNT", "--account=ACCOUNT", "Société (sinon déduite du chemin host)") { |v| account_hint = v }
        p.on("-d DOMAIN", "--domain=DOMAIN", "Domaine (sinon déduit)") { |v| domain_hint = v }
        p.on("-N", "--non-interactive", "Refuse toute invite (suppose oui)") { non_interactive = true }
        p.on("-h", "--help", "Affiche cette aide") { puts p; exit(0) }
        p.unknown_args { |rest, _| positional = rest }
      end
      parser.parse(args)

      raw = positional.first?
      unless raw
        STDERR.puts "beryl dns : hôte non précisé. USAGE : beryl dns <société>/<host> [-n]"
        return EXIT_USAGE
      end
      parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
      host_name = parsed[:host]
      account_hint ||= parsed[:account]
      domain_hint ||= parsed[:domain]

      root = Beryl::Config::Root.load(config_root)
      host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)
      host.apply_all_credentials_to_env!

      # hostname_flag/zone_flag sont closurés (assignés dans l'OptionParser)
      # → Crystal ne retire pas le Nil dans un `||`. On copie en locaux
      # non-closurés d'abord.
      hf = hostname_flag
      zf = zone_flag
      short : String = hf || host.fqdn.split('.').first
      zone : String = zf || host.domain_name
      fqdn = "#{short}.#{zone}"

      # --- résolution des providers ---------------------------------------
      dns_provider_name = host.dns_provider
      if dns_provider_name.nil? || dns_provider_name.empty?
        STDERR.puts "beryl dns : aucun `dns_provider` pour #{host.fqdn} (déclarez-le dans le .domain.yml)."
        return EXIT_USAGE
      end
      compute_provider_name = host.provider
      if compute_provider_name.nil? || compute_provider_name.empty?
        STDERR.puts "beryl dns : aucun `provider` (compute) pour #{host.fqdn}."
        return EXIT_USAGE
      end

      dns_prov = Beryl::Providers.find(dns_provider_name)
      unless dns_prov && dns_prov.capable_of?(:dns)
        STDERR.puts "beryl dns : `#{dns_provider_name}` n'est pas un DNS provider (capability :dns absente)."
        return EXIT_USAGE
      end
      compute_prov = Beryl::Providers.find(compute_provider_name)
      unless compute_prov
        STDERR.puts "beryl dns : provider compute `#{compute_provider_name}` inconnu."
        return EXIT_USAGE
      end

      # --- détection d'IP (compute-spécifique : OVH pour l'instant) -------
      unless compute_provider_name == "ovh"
        STDERR.puts "beryl dns : détection d'IP non câblée pour provider=#{compute_provider_name} " \
                    "(OVH seulement aujourd'hui). Scaleway/Dedibox à venir."
        return EXIT_USAGE
      end
      maybe_service = host.ovh_service_name
      if maybe_service.nil?
        STDERR.puts "beryl dns : host OVH sans `ovh.service_name`."
        return EXIT_USAGE
      end
      service_name = maybe_service.not_nil!

      log = ->(m : String) { STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl dns] #{m}"; nil }

      ovh = Beryl::CLI::Credentials.ovh_client
      plan = Beryl::CLI::DnsSetup.build_plan(ovh, service_name, short, zone)
      ipv4 = plan.ipv4
      ipv6 = plan.ipv6

      # --- plan ------------------------------------------------------------
      STDERR.puts
      STDERR.puts "Plan DNS pour #{fqdn}"
      STDERR.puts "─" * 60
      STDERR.puts "  forward (#{dns_provider_name}) : A    #{short}.#{zone}  →  #{ipv4}"
      STDERR.puts "  forward (#{dns_provider_name}) : AAAA #{short}.#{zone}  →  #{ipv6}" if ipv6
      STDERR.puts "  reverse (#{compute_provider_name})    : #{ipv4}  →  #{fqdn}"
      STDERR.puts "  reverse (#{compute_provider_name})    : #{ipv6}  →  #{fqdn}" if ipv6
      if plan.current_display_name != fqdn
        STDERR.puts "  rename  (#{compute_provider_name})    : #{service_name}  →  #{fqdn}"
      end
      STDERR.puts "─" * 60

      if dry_run
        STDERR.puts "DRY-RUN : aucun appel API effectué."
        return EXIT_OK
      end
      unless non_interactive
        STDERR.print "Exécuter ces actions ? [o/N] : "
        ans = (gets || "").strip.downcase
        unless ans.starts_with?("o") || ans.starts_with?("y")
          STDERR.puts "Abandon."
          return EXIT_ABORTED
        end
      end

      # `ensure_record`/`refresh_zone`/`set_reverse` vivent sur le mixin
      # DnsProvider. `Providers.find` rend `Provider+` → on caste après le
      # check de capability (`capable_of?(:dns)` garantit l'inclusion).
      dns_fwd = dns_prov.as(Beryl::DnsProvider)

      # --- exécution (résiliente par étape) --------------------------------
      # Le FORWARD est le but principal (host joignable par son nom) → un
      # échec là est bloquant. Le reverse et le rename sont secondaires :
      # leurs échecs sont collectés mais n'annulent pas le reste (ex. le
      # reverse IPv6 OVH peut 404 si l'IP devinée n'est pas la bonne).
      warnings = [] of String

      # 1. forward via le dns_provider de la zone (BLOQUANT)
      begin
        dns_fwd.ensure_record(zone, "A", short, ipv4)
        log.call("✓ A    #{fqdn} → #{ipv4}")
        if v6 = ipv6
          dns_fwd.ensure_record(zone, "AAAA", short, v6)
          log.call("✓ AAAA #{fqdn} → #{v6}")
        end
        dns_fwd.refresh_zone(zone)
      rescue ex
        STDERR.puts "beryl dns : échec du forward (#{dns_provider_name}) — #{ex.message}"
        return EXIT_RUNTIME
      end

      # 2. reverse via le compute provider (best-effort, propriétaire de l'IP)
      if compute_prov.capable_of?(:dns)
        rev = compute_prov.as(Beryl::DnsProvider)
        begin
          rev.set_reverse(ipv4, fqdn)
          log.call("✓ reverse #{ipv4} → #{fqdn}")
        rescue ex
          warnings << "reverse IPv4 (#{compute_provider_name}) : #{ex.message}"
        end
        if v6 = ipv6
          begin
            rev.set_reverse(v6, fqdn)
            log.call("✓ reverse #{v6} → #{fqdn}")
          rescue ex
            warnings << "reverse IPv6 (#{compute_provider_name}) : #{ex.message}"
          end
        end
      else
        warnings << "reverse non posé : `#{compute_provider_name}` n'expose pas le reverse DNS."
      end

      # 3. rename panel (best-effort, OVH displayName)
      if plan.current_display_name != fqdn
        begin
          Beryl::CLI::DnsSetup.update_display_name(ovh, service_name, fqdn, log)
        rescue ex
          warnings << "rename (#{compute_provider_name}) : #{ex.message}"
        end
      end

      # --- bilan -----------------------------------------------------------
      if warnings.empty?
        log.call("terminé : #{fqdn} (forward + reverse + rename)")
        return EXIT_OK
      end
      STDERR.puts
      STDERR.puts "beryl dns : forward DNS posé ✓, mais des étapes SECONDAIRES ont échoué :"
      warnings.each { |w| STDERR.puts "  ⚠ #{w}" }
      STDERR.puts "  (Le host est joignable par son nom. Corrigez le reverse/rename à la main si besoin.)"
      EXIT_OK

      log.call("terminé : #{fqdn}")
      EXIT_OK
    end
  end
end
