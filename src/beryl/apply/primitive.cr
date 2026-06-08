require "yaml"
require "./shell"

module Beryl::Apply
  # Issue de l'exécution d'un step (une invocation de primitive).
  #
  # * `skipped`  : l'état était déjà conforme, rien fait.
  # * `applied`  : une modification a été appliquée (ou le serait hors
  #   dry-run).
  # * `failed`   : l'exécution a échoué (réservé ; en pratique les
  #   primitives lèvent une exception, capturée par l'`Executor`).
  enum Outcome
    Skipped
    Applied
    Failed
  end

  # Résultat d'un step : son `outcome` et un message lisible pour le
  # rapport (« nginx déjà installé », « +2 packages : zsh, tmux »).
  record StepResult, outcome : Outcome, message : String do
    def self.skipped(message : String) : StepResult
      new(Outcome::Skipped, message)
    end

    def self.applied(message : String) : StepResult
      new(Outcome::Applied, message)
    end

    def self.failed(message : String) : StepResult
      new(Outcome::Failed, message)
    end
  end

  # Tâche élémentaire idempotente exécutée sur l'hôte distant. Chaque
  # primitive lit l'état réel via `shell` avant d'agir et retourne un
  # `StepResult`. En `dry_run`, elle calcule le delta mais n'applique
  # rien (`Outcome::Applied` annonce alors ce qui *serait* fait).
  abstract class Primitive
    # Nom kebab-case utilisé comme clé de step dans les recettes
    # (« pkg-install », « service-enable », …).
    abstract def name : String

    # `params` est le hash brut du step YAML (ex: `{"packages" => [...]}`),
    # déjà interpolé par l'`Executor`.
    abstract def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool) : StepResult

    # Registre global nom → instance de primitive. Peuplé par chaque
    # fichier de primitive via `Primitive.register`.
    @@registry = {} of String => Primitive

    def self.register(primitive : Primitive) : Nil
      @@registry[primitive.name] = primitive
    end

    def self.[]?(name : String) : Primitive?
      @@registry[name]?
    end

    def self.registry : Hash(String, Primitive)
      @@registry
    end

    # Helpers de lecture typée des params, tolérants au YAML (`as_a?`,
    # `as_s?`) — factorisés ici pour toutes les primitives.

    # Liste de strings depuis `params[key]` (vide si absent ou mal typé).
    protected def string_array(params : Hash(String, YAML::Any), key : String) : Array(String)
      val = params[key]?
      return [] of String unless val
      (val.as_a? || [] of YAML::Any).compact_map(&.as_s?)
    end

    # Scalaire string depuis `params[key]` (nil si absent ou mal typé).
    protected def string(params : Hash(String, YAML::Any), key : String) : String?
      params[key]?.try(&.as_s?)
    end
  end
end
