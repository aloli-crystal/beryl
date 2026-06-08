require "../primitive"

module Beryl::Apply
  # Primitive `pf-rule` : ajoute/retire une règle dans un bloc géré par
  # beryl à l'intérieur de `/etc/pf.conf`. Le reste du fichier (macros,
  # tables, règles de l'opérateur) n'est jamais touché.
  #
  # Idempotence : diff par ligne dans le bloc géré (marqueurs
  # `# >>> beryl >>>` / `# <<< beryl <<<`). La règle est validée
  # (`pfctl -nf` sur un fichier temporaire) AVANT d'écraser pf.conf,
  # puis chargée (`pfctl -f`).
  #
  #     - pf-rule:
  #         rule: "block in quick proto tcp to port 23"
  #         state: present     # ou absent (défaut present)
  class PfRule < Primitive
    PATH      = "/etc/pf.conf"
    TMP       = "/etc/pf.conf.beryl.tmp"
    BEGIN_TAG = "# >>> beryl >>>"
    END_TAG   = "# <<< beryl <<<"

    def name : String
      "pf-rule"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      rule = required_string(params, "rule").strip
      state = string(params, "state") || "present"

      content = shell.exec("cat #{Process.quote(PATH)} 2>/dev/null", raise_on_error: false).stdout
      before, block, after, had_block = split_managed(content)

      present = block.includes?(rule)
      case state
      when "present"
        if present
          return StepResult.skipped("règle pf déjà présente")
        end
        block << rule
        verb = "ajout"
      when "absent"
        unless present
          return StepResult.skipped("règle pf déjà absente")
        end
        block.reject! { |l| l == rule }
        verb = "retrait"
      else
        raise MissingParam.new("`state` doit valoir present ou absent (reçu #{state.inspect}).")
      end

      msg = "pf : #{verb} « #{rule} »"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      new_content = rebuild(before, block, after, had_block)
      shell.write_file(TMP, new_content)
      # Valide la conf complète AVANT de la mettre en place (échec =
      # stop net, pf.conf courant intact).
      shell.exec("pfctl -nf #{Process.quote(TMP)}")
      shell.exec("mv #{Process.quote(TMP)} #{Process.quote(PATH)}")
      shell.exec("pfctl -f #{Process.quote(PATH)}")
      StepResult.applied(msg)
    end

    # Découpe le contenu en (avant, lignes du bloc, après, bloc_présent).
    private def split_managed(content : String) : {Array(String), Array(String), Array(String), Bool}
      lines = content.empty? ? [] of String : content.lines.map(&.chomp)
      bi = lines.index(BEGIN_TAG)
      ei = lines.index(END_TAG)
      if bi && ei && ei > bi
        before = lines[0...bi]
        block = lines[(bi + 1)...ei].reject(&.strip.empty?)
        after = lines[(ei + 1)..]
        {before, block, after, true}
      else
        {lines, [] of String, [] of String, false}
      end
    end

    # Reconstruit le fichier. Si le bloc est vide et n'existait pas, on
    # ne l'ajoute pas (pas de churn inutile).
    private def rebuild(before : Array(String), block : Array(String), after : Array(String), had_block : Bool) : String
      String.build do |io|
        before.each { |l| io << l << '\n' }
        if !block.empty? || had_block
          io << BEGIN_TAG << '\n'
          block.each { |l| io << l << '\n' }
          io << END_TAG << '\n'
        end
        after.each { |l| io << l << '\n' }
      end
    end
  end

  Primitive.register(PfRule.new)
end
