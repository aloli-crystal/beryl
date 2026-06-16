require "option_parser"
require "yaml"
require "../config"

module Beryl::CLI
  # `beryl vrack-ip [--check|--gather|--distribute] [-a société]` : gère la
  # numérotation des IP vRack de façon centralisée.
  #
  #   --check       (défaut) valide TOUTE la numérotation : collisions, IP
  #                 hors sous-réseau. Exit ≠ 0 si un problème. C'est le
  #                 garde-fou contre deux hôtes sur la même IP.
  #   --gather      hosts → fichier consolidé `<société>/vrack.yml`.
  #   --distribute  fichier consolidé → host.yml (injecte l'IP, préserve
  #                 commentaires/format).
  #
  # Source de vérité = vous : `--gather` et `--distribute` sont explicites,
  # aucun sens n'écrase l'autre tout seul ; `--check` valide toujours.
  module VrackIp
    EXIT_OK      = 0
    EXIT_USAGE   = 1
    EXIT_PROBLEM = 2 # --check a trouvé une collision / une IP hors-réseau

    DEFAULT_SUBNET = "192.168.42.0/24"
    REGISTRY_FILE  = "vrack.yml"

    # Une IP vRack déclarée par un host (nom court + IP + fichier source).
    record Entry, host : String, ip : String, source_path : String

    def self.run(config_root : String, args : Array(String)) : Int32
      mode = :check
      account_hint : String? = nil
      parser = OptionParser.new do |p|
        p.banner = "USAGE : beryl vrack-ip [--check|--gather|--distribute] [-a société]"
        p.on("--check", "Valide la numérotation (défaut) : collisions, hors-réseau") { mode = :check }
        p.on("--gather", "hosts → <société>/vrack.yml") { mode = :gather }
        p.on("--distribute", "<société>/vrack.yml → host.yml") { mode = :distribute }
        p.on("-a NAME", "--account=NAME", "Limiter à une société") { |v| account_hint = v }
        p.on("-h", "--help", "Aide") { puts p; exit 0 }
      end
      parser.parse(args)

      root = Beryl::Config::Root.load(config_root)
      by_account = collect_by_account(root)
      if hint = account_hint
        by_account.select! { |account, _| account.name == hint }
        if by_account.empty?
          STDERR.puts "beryl : aucune IP vRack pour la société #{hint}."
          return EXIT_USAGE
        end
      end
      if by_account.empty?
        STDERR.puts "beryl : aucun host avec une IP vRack (`vrack-interface`) — rien à faire."
        return EXIT_USAGE
      end

      case mode
      when :gather     then gather_all(by_account)
      when :distribute then distribute_all(root, by_account)
      else                  check_all(by_account)
      end
    rescue ex
      STDERR.puts "beryl : erreur vrack-ip — #{ex.message}"
      EXIT_USAGE
    end

    # ─── Collecte (hosts → entries, groupées par société) ───────────────────

    def self.collect_by_account(root : Beryl::Config::Root) : Hash(Beryl::Config::Account, Array(Entry))
      acc = {} of Beryl::Config::Account => Array(Entry)
      root.all_hosts_by_fqdn.each do |fqdn, info|
        host = begin
          root.resolve(fqdn)
        rescue
          next
        end
        next unless ip = host.vrack_ip
        (acc[info[:account]] ||= [] of Entry) << Entry.new(fqdn.split('.').first, ip, info[:node].source_path)
      end
      acc
    end

    # ─── Cœur pur (testable, sans IO) ───────────────────────────────────────

    # IP → [hôtes] pour les IP portées par PLUS d'un hôte (collisions).
    def self.collisions(entries : Array(Entry)) : Hash(String, Array(String))
      by_ip = {} of String => Array(String)
      entries.each { |e| (by_ip[e.ip] ||= [] of String) << e.host }
      by_ip.select { |_, hosts| hosts.size > 1 }
    end

    # Entries dont l'IP n'est pas dans le /24 du sous-réseau.
    def self.out_of_subnet(entries : Array(Entry), subnet : String) : Array(Entry)
      prefix = subnet_prefix(subnet)
      entries.reject { |e| e.ip.starts_with?(prefix) }
    end

    # "192.168.42.0/24" → "192.168.42." (préfixe /24).
    def self.subnet_prefix(subnet : String) : String
      base = subnet.split('/').first
      base.split('.').first(3).join('.') + "."
    end

    # Clé de tri par dernier octet numérique.
    def self.ip_sort_key(ip : String) : Array(Int32)
      ip.split('.').map(&.to_i)
    end

    # Rend le `vrack.yml` consolidé (trié par IP). Pur.
    def self.render(vrack : String, subnet : String, entries : Array(Entry)) : String
      String.build do |io|
        io << "# Registre des IP vRack — maintenu par `beryl vrack-ip`.\n"
        io << "#   --gather (hosts→ici) · --distribute (ici→hosts) · --check (validation)\n"
        io << "vrack: #{vrack}\n"
        io << "subnet: #{subnet}\n"
        io << "hosts:\n"
        entries.sort_by { |e| ip_sort_key(e.ip) }.each do |e|
          io << "  #{e.host}: #{e.ip}\n"
        end
      end
    end

    # Remplace l'IP dans une ligne `vrack-interface: { ip: … }` (gère le variant
    # `{ ip: X, iface: Y }`), en préservant tout le reste. Renvoie {contenu, modifié?}.
    VRACK_IP_RE = /(vrack-interface:\s*\{[^}]*\bip:\s*)([0-9.]+)/

    def self.replace_vrack_ip(content : String, ip : String) : {String, Bool}
      return {content, false} unless content.matches?(VRACK_IP_RE)
      updated = content.gsub(VRACK_IP_RE) { "#{$1}#{ip}" }
      {updated, updated != content}
    end

    def self.has_vrack_interface?(content : String) : Bool
      content.matches?(VRACK_IP_RE)
    end

    # Parse les couples host→ip de la section `hosts:` d'un vrack.yml. Pur.
    def self.parse_registry(yaml : String) : Hash(String, String)
      reg = {} of String => String
      doc = YAML.parse(yaml)
      if hosts = doc["hosts"]?
        hosts.as_h.each { |k, v| reg[k.as_s] = v.as_s }
      end
      reg
    rescue
      {} of String => String
    end

    # ─── Modes (IO en périphérie) ───────────────────────────────────────────

    private def self.check_all(by_account : Hash(Beryl::Config::Account, Array(Entry))) : Int32
      problems = 0
      by_account.each do |account, entries|
        subnet = registry_field(account, "subnet") || DEFAULT_SUBNET
        log "société #{account.name} — #{entries.size} hôte(s), sous-réseau #{subnet}"

        cols = collisions(entries)
        cols.each do |ip, hosts|
          problems += 1
          STDERR.puts "  ✗ COLLISION #{ip} ← #{hosts.sort.join(", ")}"
        end

        oos = out_of_subnet(entries, subnet)
        oos.each do |e|
          problems += 1
          STDERR.puts "  ✗ HORS-RÉSEAU #{e.host} → #{e.ip} (hors #{subnet})"
        end

        if cols.empty? && oos.empty?
          entries.sort_by { |e| ip_sort_key(e.ip) }.each { |e| log "  ✓ #{e.ip.ljust(15)} #{e.host}" }
        end
      end
      if problems.zero?
        log "numérotation vRack OK ✅"
        EXIT_OK
      else
        STDERR.puts "beryl : #{problems} problème(s) de numérotation vRack."
        EXIT_PROBLEM
      end
    end

    private def self.gather_all(by_account : Hash(Beryl::Config::Account, Array(Entry))) : Int32
      by_account.each do |account, entries|
        path = File.join(account.path, REGISTRY_FILE)
        vrack = registry_field(account, "vrack") || "pn-XXXX (à renseigner)"
        subnet = registry_field(account, "subnet") || DEFAULT_SUBNET
        File.write(path, render(vrack, subnet, entries))
        log "écrit #{path} — #{entries.size} hôte(s)"
      end
      EXIT_OK
    end

    private def self.distribute_all(root : Beryl::Config::Root, by_account : Hash(Beryl::Config::Account, Array(Entry))) : Int32
      # chemin de TOUS les hosts (même ceux sans IP vRack encore) pour pouvoir injecter.
      paths = {} of String => String
      root.all_hosts_by_fqdn.each { |fqdn, info| paths[fqdn.split('.').first] = info[:node].source_path }

      changed = 0
      by_account.each_key do |account|
        path = File.join(account.path, REGISTRY_FILE)
        unless File.exists?(path)
          STDERR.puts "  ⚠ #{account.name} : pas de #{REGISTRY_FILE} — lancez d'abord `--gather`."
          next
        end
        registry = parse_registry(File.read(path))
        registry.each do |host, ip|
          src = paths[host]?
          unless src
            STDERR.puts "  ⚠ #{host} (du registre) : aucun host.yml correspondant."
            next
          end
          content = File.read(src)
          unless has_vrack_interface?(content)
            STDERR.puts "  ⚠ #{host} : pas de ligne `vrack-interface` → ajoutez-la à la main une fois."
            next
          end
          updated, did = replace_vrack_ip(content, ip)
          if did
            File.write(src, updated)
            changed += 1
            log "  ✓ #{host} → #{ip} (#{File.basename(src)})"
          else
            log "  = #{host} déjà à #{ip}"
          end
        end
      end
      log "distribute terminé — #{changed} fichier(s) modifié(s)"
      EXIT_OK
    end

    # ─── Helpers IO ─────────────────────────────────────────────────────────

    # Lit un champ scalaire (`vrack:`/`subnet:`) du vrack.yml de la société, ou nil.
    private def self.registry_field(account : Beryl::Config::Account, field : String) : String?
      path = File.join(account.path, REGISTRY_FILE)
      return nil unless File.exists?(path)
      doc = YAML.parse(File.read(path))
      doc[field]?.try(&.as_s?)
    rescue
      nil
    end

    private def self.log(message : String) : Nil
      STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl vrack-ip] #{message}"
    end
  end
end
