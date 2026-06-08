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

  # Contexte d'exécution transmis aux primitives, porteur d'infos
  # dérivées du host qui ne tiennent pas dans les params d'un step.
  #
  # * `protected_keys` : clés publiques SSH que beryl utilise pour se
  #   connecter (dérivées de `host.identity_file`). La primitive
  #   `user-update-keys` refuse de les retirer — garde-fou pour ne pas
  #   se couper la branche sur laquelle on est assis en plein apply.
  record Context, protected_keys : Array(String) = [] of String

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
    # déjà interpolé par l'`Executor`. `context` porte les infos
    # dérivées du host (cf. `Context`).
    abstract def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult

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
    # Tolère aussi un scalaire entier/booléen (rendu en string), pour
    # accepter `value: 22` ou `value: yes` sans guillemets côté YAML.
    protected def string(params : Hash(String, YAML::Any), key : String) : String?
      val = params[key]?
      return nil unless val
      if s = val.as_s?
        s
      elsif (i = val.as_i64?)
        i.to_s
      elsif !val.as_bool?.nil?
        val.as_bool.to_s
      else
        nil
      end
    end

    # Comme `string` mais lève `MissingParam` si absent — pour les
    # paramètres obligatoires (`name`, `path`, `key`, …).
    protected def required_string(params : Hash(String, YAML::Any), key : String) : String
      string(params, key) || raise MissingParam.new(
        "paramètre `#{key}` obligatoire et manquant pour la primitive `#{name}`."
      )
    end

    # Booléen depuis `params[key]` (défaut `default` si absent).
    protected def bool(params : Hash(String, YAML::Any), key : String, default : Bool = false) : Bool
      val = params[key]?
      return default unless val
      b = val.as_bool?
      b.nil? ? default : b
    end

    # Base des erreurs « métier » d'une primitive (param manquant,
    # garde-fou déclenché, …). L'`Executor` les traite comme un step
    # `failed` (stop net) plutôt que comme un crash inattendu.
    class PrimitiveError < Exception
    end

    # Levée quand un paramètre obligatoire d'un step est absent.
    class MissingParam < PrimitiveError
    end
  end
end
