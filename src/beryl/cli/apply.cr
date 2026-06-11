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
      p.banner = "USAGE : beryl apply <host> [recette] [options]"
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
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl apply <host> [recette]"
      return EXIT_USAGE
    end
    # 2e positionnel optionnel : une recette nommée à appliquer en
    # ONE-OFF (non persistée dans la config), ex. une rotation de clé.
    adhoc_recipe = positional[1]?
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
      log "aucune recette pour #{host.fqdn} (host virtuel : pas de fichier .host.yml, donc pas de connexion)."
      return EXIT_OK
    end

    central_dir = central_recipes_dir(config_root, host)

    # Recettes d'ENTRÉE : soit une recette nommée en argument (one-off,
    # non persistée — ex. une rotation de clé), soit la liste
    # `apply_recipes:` cascadée du merge (état désiré, versionné dans la
    # config société → domaine → host).
    requests =
      if r = adhoc_recipe
        [RecipeRequest.new(r, {} of String => String)]
      else
        apply_recipes_list(host)
      end
    resolver = Beryl::Apply::Resolver.new(central_dir)
    recipes = resolver.resolve(requests.map(&.name).uniq)
    if recipes.empty?
      log "aucune recette pour #{host.fqdn} (ni recette en argument, ni `apply_recipes:` dans la config)."
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
    context = Beryl::Apply::Context.new(
      protected_keys: connecting_pubkeys(host),
      vars: {
        "company"  => host.account_name,
        "fqdn"     => host.fqdn,
        "hostname" => host.short_name,
        "domain"   => host.domain_name,
      },
    )
    recipe_args = {} of String => Array(Hash(String, String))
    requests.each { |req| (recipe_args[req.name] ||= [] of Hash(String, String)) << req.arguments }
    report = Beryl::Apply::Executor.new(shell, dry_run, context).run(recipes, recipe_args)

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

  # Une recette demandée + ses arguments éventuels (qui surchargent les
  # `parameters` de la recette pour CET hôte).
  record RecipeRequest, name : String, arguments : Hash(String, String)

  # Recettes d'entrée déclarées en config (`apply_recipes:`), cascadées
  # par le merge (société → domaine → host, append + dédup). Chaque entrée
  # est soit un NOM (string), soit une map à CLÉ UNIQUE `{<nom>: {clé:
  # valeur}}` pour passer des arguments — même forme que les steps d'une
  # recette. Ex. cibler un user particulier :
  #
  #   apply_recipes:
  #     - ssh-hardening
  #     - oh-my-zsh: { user: pne }
  private def self.apply_recipes_list(host : Beryl::Config::ResolvedHost) : Array(RecipeRequest)
    any = host.merged[YAML::Any.new("apply_recipes")]?
    return [] of RecipeRequest unless any
    (any.as_a? || [] of YAML::Any).flat_map do |e|
      if name = e.as_s?
        [RecipeRequest.new(name, {} of String => String)]
      elsif (h = e.as_h?) && !h.empty? && (rname = h.first[0].as_s?)
        # Args bruts : chaque clé → liste de valeurs (string → [v], liste
        # → [v1, v2…]). Le produit cartésien donne un jeu d'args par
        # combinaison → fan-out (ex. `user: [deploy, pne]` → 2 jeux).
        raw = {} of String => Array(String)
        if argh = h.first[1].as_h?
          argh.each do |k, v|
            kn = k.as_s? || k.to_s
            if vs = v.as_s?
              raw[kn] = [vs]
            elsif va = v.as_a?
              raw[kn] = va.compact_map(&.as_s?)
            end
          end
        end
        expand_args(raw).map { |combo| RecipeRequest.new(rname, combo) }
      else
        [] of RecipeRequest
      end
    end
  end

  # Produit cartésien des arguments listes → un jeu d'arguments par
  # combinaison. `{}` → `[{}]` (une exécution, jeu vide) ; `{user: [a, b]}`
  # → `[{user: a}, {user: b}]` ; `{u: [a, b], t: [x, y]}` → 4 combinaisons.
  private def self.expand_args(raw : Hash(String, Array(String))) : Array(Hash(String, String))
    combos = [{} of String => String]
    raw.each do |key, values|
      combos = combos.flat_map { |c| values.map { |v| c.merge({key => v}) } }
    end
    combos
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
