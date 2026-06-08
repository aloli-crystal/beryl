require "./recipe"

module Beryl::Apply
  # Résout l'ensemble des recettes à exécuter pour un host et leur
  # ordre.
  #
  # Entrées :
  #   * `host_dir`    : dossier d'orchestration du host
  #     (`~/.config/beryl/<société>/<domaine>/<host>/`). Les `*.yml`
  #     qu'il contient sont les recettes *explicitement demandées*.
  #   * `central_dir` : dossier `recipes/` du dépôt central
  #     (`~/.config/beryl/recipes/recipes/`).
  #
  # Étapes :
  #   1. Scan de `host_dir` → recettes demandées.
  #   2. Fermeture transitive des `requires:` — pour chaque recette R,
  #      on cherche `R.yml` d'abord dans `host_dir` (override), sinon
  #      dans `central_dir`. Introuvable → `RecipeNotFound`.
  #   3. Tri topologique (Kahn) : les dépendances sortent avant leurs
  #      dépendants. Tri alphabétique à indegree égal pour un ordre
  #      déterministe.
  #   4. Cycle → `Cycle` (liste des recettes impliquées).
  class Resolver
    # Levée quand une recette référencée (demandée ou via `requires:`)
    # est introuvable dans le dossier host comme dans le dépôt central.
    class RecipeNotFound < Exception
    end

    # Levée quand le graphe des `requires:` contient un cycle.
    class Cycle < Exception
      getter recipes : Array(String)

      def initialize(@recipes : Array(String))
        super("cycle de dépendances entre recettes : #{@recipes.join(" → ")}")
      end
    end

    def initialize(@host_dir : String, @central_dir : String)
    end

    # Retourne les recettes dans l'ordre d'exécution (dépendances
    # d'abord). Liste vide si le dossier host n'existe pas ou ne
    # contient aucune recette.
    def resolve : Array(Recipe)
      requested = scan_host_dir
      return [] of Recipe if requested.empty?

      loaded = {} of String => Recipe
      requested.each { |name| load_closure(name, requirer: nil, loaded: loaded) }
      topo_sort(loaded)
    end

    # Noms des recettes explicitement demandées (fichiers `*.yml` du
    # dossier host), triés.
    def scan_host_dir : Array(String)
      return [] of String unless Dir.exists?(@host_dir)
      Dir.glob(File.join(@host_dir, "*.yml"))
        .map { |p| File.basename(p, ".yml") }
        .sort
    end

    # Localise et charge `R.yml` : override dossier host prioritaire,
    # sinon dépôt central.
    private def lookup(name : String, requirer : String?) : Recipe
      host_path = File.join(@host_dir, "#{name}.yml")
      return Recipe.load(host_path) if File.exists?(host_path)

      central_path = File.join(@central_dir, "#{name}.yml")
      return Recipe.load(central_path) if File.exists?(central_path)

      origin = requirer ? " (requise par `#{requirer}`)" : ""
      raise RecipeNotFound.new(
        "recette `#{name}` introuvable#{origin}. Symlinkez-la dans le " \
        "dossier du host ou ajoutez-la au dépôt central.\n" \
        "  cherchée dans : #{host_path}\n" \
        "             et : #{central_path}"
      )
    end

    # Charge récursivement `name` et toutes ses dépendances dans
    # `loaded` (dédup par nom).
    private def load_closure(name : String, requirer : String?, loaded : Hash(String, Recipe)) : Nil
      return if loaded.has_key?(name)
      recipe = lookup(name, requirer)
      loaded[name] = recipe
      recipe.requires.each do |dep|
        load_closure(dep, requirer: name, loaded: loaded)
      end
    end

    # Tri topologique de Kahn. À indegree égal, ordre alphabétique.
    private def topo_sort(loaded : Hash(String, Recipe)) : Array(Recipe)
      indegree = {} of String => Int32
      loaded.each_key { |n| indegree[n] = 0 }
      dependents = {} of String => Array(String)
      loaded.each do |name, recipe|
        recipe.requires.each do |dep|
          indegree[name] += 1
          (dependents[dep] ||= [] of String) << name
        end
      end

      ready = indegree.select { |_, d| d == 0 }.keys.sort
      result = [] of Recipe
      until ready.empty?
        n = ready.shift
        result << loaded[n]
        (dependents[n]? || [] of String).sort.each do |m|
          indegree[m] -= 1
          ready << m if indegree[m] == 0
        end
        ready.sort!
      end

      if result.size != loaded.size
        remaining = (loaded.keys - result.map(&.name)).sort
        raise Cycle.new(remaining)
      end

      result
    end
  end
end
