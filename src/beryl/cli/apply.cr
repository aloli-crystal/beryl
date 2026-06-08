require "option_parser"
require "../config"
require "../apply"
require "ssh"
require "./account_utils"

# Sous-commande `beryl apply <host>` : applique sur le serveur FreeBSD
# (déjà bootstrappé) les *recettes* déclarées dans le dossier
# d'orchestration du host.
#
# Architecture à 2 niveaux (cf. `apply-recipes-architecture.adoc`) :
#   * recettes YAML reliées par `requires:` (résolution récursive,
#     tri topologique, détection de cycle) ;
#   * primitives Crystal natives idempotentes (`pkg-install`, …).
#
# Dossiers lus :
#   * orchestration du host : `<config>/<société>/<domaine>/<host>/`
#     (recettes explicitement demandées + overrides locaux) ;
#   * dépôt central : `<recipes.local_path>/recipes/`
#     (défaut `<config>/recipes/recipes/`).
#
# Priorité de résolution : dossier host > dépôt central. Idempotence :
# chaque primitive lit l'état réel via SSH avant d'agir. `--dry-run`
# (alias `--check`) calcule sans rien modifier.
module Beryl::CLI::Apply
  EXIT_OK         =  0
  EXIT_USAGE      =  1
  EXIT_UNEXPECTED =  3
  EXIT_SSH_FAILED =  4
  EXIT_NO_FREEBSD = 10
  EXIT_RECIPE     = 11

  def self.run(config_root : String, args : Array(String)) : Int32
    dry_run = false
    account_hint : String? = nil
    domain_hint : String? = nil
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl apply <host> [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-n", "--dry-run", "Affiche ce qui changerait sans l'appliquer") { dry_run = true }
      p.on("--check", "Synonyme de --dry-run (lecture seule)") { dry_run = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl apply <host>"
      return EXIT_USAGE
    end
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    host_name = parsed[:host]
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)
    host.apply_all_credentials_to_env!

    # Apply est FreeBSD-only dans ce build. L'architecture ADR-014
    # prévoit des `Os::Debian`, `Os::Ubuntu`, etc. — pas câblés ici.
    unless host.os == "freebsd"
      STDERR.puts "beryl : apply n'est implémenté que pour os: freebsd (host : #{host.os})."
      return EXIT_USAGE
    end

    # Un host virtuel (pas de fichier `<host>.host.yml`) n'a pas de
    # dossier d'orchestration — rien à appliquer.
    if host.virtual
      log "aucune recette pour #{host.fqdn} (host virtuel, pas de dossier d'orchestration)."
      return EXIT_OK
    end

    # Dossier d'orchestration : à côté du fichier host, dérivé de son
    # `source_path` (`<host>.host.yml` → `<host>/`). Correct aussi
    # pour un host en groupe (`<groupe>/<host>.host.yml` → `<groupe>/<host>/`).
    host_dir = host.node.source_path.rchop(Beryl::Config::Loader::HOST_SUFFIX)
    central_dir = central_recipes_dir(config_root, host)

    resolver = Beryl::Apply::Resolver.new(host_dir, central_dir)
    recipes = resolver.resolve
    if recipes.empty?
      log "aucune recette pour #{host.fqdn} (dossier #{host_dir} absent ou vide)."
      return EXIT_OK
    end

    log "cible : #{Beryl.format_ssh_target(host)} (user SSH : #{host.user})"
    log "recettes (ordre résolu) : #{recipes.map(&.name).join(" → ")}"

    conn = host.connection
    uname = conn.exec("uname -s", raise_on_error: false).stdout.strip
    unless uname == "FreeBSD"
      STDERR.puts "beryl : #{host.fqdn} n'est pas sur FreeBSD (uname -s = #{uname.inspect})"
      return EXIT_NO_FREEBSD
    end

    shell = Beryl::Apply::SshShell.new(conn)
    context = Beryl::Apply::Context.new(protected_keys: connecting_pubkeys(host))
    report = Beryl::Apply::Executor.new(shell, dry_run, context).run(recipes)

    log "apply terminé pour #{host.fqdn}#{dry_run ? " (dry-run)" : ""} — #{report.summary_line}"
    report.failed > 0 ? EXIT_RECIPE : EXIT_OK
  rescue ex : Beryl::Config::Root::HostNotFound
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : Beryl::Config::Root::AmbiguousHost
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : Beryl::Config::Root::UnknownDomain
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : Beryl::Apply::Resolver::RecipeNotFound
    STDERR.puts "beryl : #{ex.message}"
    EXIT_RECIPE
  rescue ex : Beryl::Apply::Resolver::Cycle
    STDERR.puts "beryl : #{ex.message}"
    EXIT_RECIPE
  rescue ex : Beryl::Apply::Recipe::InvalidRecipe
    STDERR.puts "beryl : #{ex.message}"
    EXIT_RECIPE
  rescue ex : Beryl::Apply::UnknownPrimitive
    STDERR.puts "beryl : #{ex.message}"
    EXIT_RECIPE
  rescue ex : SSH::CommandFailed
    STDERR.puts "beryl : #{ex.message}"
    EXIT_SSH_FAILED
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  # Dossier `recipes/` du dépôt central. Lit le bloc `recipes:` du
  # merge (`local_path`, défaut `<config>/recipes`). Le dépôt central
  # est cloné/maintenu hors de beryl (Phase 1) ; les recettes vivent
  # dans son sous-dossier `recipes/`.
  private def self.central_recipes_dir(config_root : String, host : Beryl::Config::ResolvedHost) : String
    block = host.merged[YAML::Any.new("recipes")]?.try(&.as_h?)
    local_path =
      if block && (lp = block[YAML::Any.new("local_path")]?.try(&.as_s?))
        File.expand_path(lp, home: true)
      else
        File.join(config_root, "recipes")
      end
    File.join(local_path, "recipes")
  end

  # Clé(s) publique(s) que beryl utilise pour se connecter, dérivée(s)
  # de `host.identity_file` via `ssh-keygen -y`. Alimente le garde-fou
  # de `user-update-keys` (refus de retirer la clé en cours d'usage).
  # Best-effort : si la clé est absente, chiffrée ou illisible, on
  # retourne une liste vide (pas de garde-fou plutôt qu'un plantage).
  private def self.connecting_pubkeys(host : Beryl::Config::ResolvedHost) : Array(String)
    idf = host.identity_file
    return [] of String unless idf && File.exists?(idf)
    buf = IO::Memory.new
    status = Process.run(
      "ssh-keygen",
      ["-y", "-f", idf],
      output: buf,
      error: Process::Redirect::Close,
      input: Process::Redirect::Close,
    )
    return [] of String unless status.success?
    buf.to_s.lines.map(&.strip).reject(&.empty?)
  rescue
    [] of String
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl apply] #{message}"
  end
end
