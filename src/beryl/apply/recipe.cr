require "yaml"

module Beryl::Apply
  # Un step d'une recette : l'invocation d'une primitive (ou, à terme,
  # d'une sous-recette). Format YAML = hash à une seule clé :
  #
  #     - pkg-install:
  #         packages: [bash, git]
  #
  # `name` = la clé (« pkg-install »), `params` = la valeur (le hash
  # d'arguments), tel quel et non interpolé (l'`Executor` interpole).
  record Step, name : String, params : Hash(String, YAML::Any)

  # Une recette YAML chargée et validée. Porte ses métadonnées
  # (`name`, `description`), ses dépendances (`requires`), ses
  # `parameters` (déclaration typée) / `arguments` (valeurs concrètes
  # d'une copie locale), et ses `steps`.
  class Recipe
    getter name : String
    getter description : String
    getter requires : Array(String)
    getter parameters : Hash(String, YAML::Any)
    getter arguments : Hash(String, YAML::Any)
    getter steps : Array(Step)
    getter source_path : String

    def initialize(
      @name : String,
      @description : String,
      @requires : Array(String),
      @parameters : Hash(String, YAML::Any),
      @arguments : Hash(String, YAML::Any),
      @steps : Array(Step),
      @source_path : String,
    )
    end

    # Levée si un fichier de recette est mal formé ou viole une
    # convention (nom ≠ fichier, `steps` mal typé, etc.).
    class InvalidRecipe < Exception
    end

    # Charge et valide une recette depuis un fichier `.yml`. Le nom
    # attendu (`expected_name`) est le nom de fichier sans extension :
    # la convention impose `recipe:` strictement identique.
    def self.load(path : String) : Recipe
      expected_name = File.basename(path, ".yml")
      raw =
        begin
          YAML.parse(File.read(path))
        rescue ex : YAML::ParseException
          raise InvalidRecipe.new("recette `#{path}` : YAML invalide — #{ex.message}")
        end

      root = raw.as_h? || raise InvalidRecipe.new(
        "recette `#{path}` : le document doit être un mapping YAML."
      )

      name = root[YAML::Any.new("recipe")]?.try(&.as_s?)
      raise InvalidRecipe.new(
        "recette `#{path}` : champ `recipe:` manquant ou non textuel."
      ) unless name

      unless name == expected_name
        raise InvalidRecipe.new(
          "recette `#{path}` : `recipe: #{name}` ne correspond pas au nom " \
          "de fichier (`#{expected_name}`). La convention impose l'égalité."
        )
      end

      description = root[YAML::Any.new("description")]?.try(&.as_s?) || ""
      requires = string_array(root, "requires")
      parameters = sub_hash(root, "parameters")
      arguments = sub_hash(root, "arguments")
      steps = parse_steps(root, path)

      new(
        name: name,
        description: description,
        requires: requires,
        parameters: parameters,
        arguments: arguments,
        steps: steps,
        source_path: path,
      )
    end

    private def self.string_array(root : Hash(YAML::Any, YAML::Any), key : String) : Array(String)
      val = root[YAML::Any.new(key)]?
      return [] of String unless val
      (val.as_a? || [] of YAML::Any).compact_map(&.as_s?)
    end

    private def self.sub_hash(root : Hash(YAML::Any, YAML::Any), key : String) : Hash(String, YAML::Any)
      result = {} of String => YAML::Any
      h = root[YAML::Any.new(key)]?.try(&.as_h?)
      return result unless h
      h.each do |k, v|
        ks = k.as_s?
        result[ks] = v if ks
      end
      result
    end

    private def self.parse_steps(root : Hash(YAML::Any, YAML::Any), path : String) : Array(Step)
      steps = [] of Step
      list = root[YAML::Any.new("steps")]?.try(&.as_a?)
      return steps unless list

      list.each do |entry|
        h = entry.as_h? || raise InvalidRecipe.new(
          "recette `#{path}` : chaque step doit être un mapping à une " \
          "clé (`<primitive>: { … }`)."
        )
        if h.size != 1
          raise InvalidRecipe.new(
            "recette `#{path}` : un step doit avoir exactement une clé " \
            "(la primitive). Trouvé #{h.size} clés : #{h.keys.compact_map(&.as_s?).join(", ")}."
          )
        end
        key_any, value_any = h.first
        prim_name = key_any.as_s? || raise InvalidRecipe.new(
          "recette `#{path}` : nom de primitive non textuel dans un step."
        )
        params = {} of String => YAML::Any
        if ph = value_any.as_h?
          ph.each do |pk, pv|
            pks = pk.as_s?
            params[pks] = pv if pks
          end
        end
        steps << Step.new(name: prim_name, params: params)
      end

      steps
    end
  end
end
