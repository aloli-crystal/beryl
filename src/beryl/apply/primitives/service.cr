require "../primitive"

module Beryl::Apply
  # Base commune à `service-enable` / `service-disable` : lecture de
  # l'état réel d'un service rc.d FreeBSD (`sysrc -n <svc>_enable` +
  # `service <svc> onestatus`).
  abstract class ServicePrimitive < Primitive
    # `sysrc -n <svc>_enable` vaut-il YES ? (exit 1 si la variable
    # n'est pas posée → considéré non activé).
    protected def enabled?(shell : Shell, svc : String) : Bool
      out = shell.exec("sysrc -n #{Process.quote("#{svc}_enable")} 2>/dev/null", raise_on_error: false).stdout
      out.strip.upcase == "YES"
    end

    # `service <svc> onestatus` retourne 0 si le service tourne.
    protected def running?(shell : Shell, svc : String) : Bool
      shell.exec("service #{Process.quote(svc)} onestatus", raise_on_error: false).success?
    end
  end

  # Primitive `service-enable` : `sysrc <svc>_enable=YES` puis démarre
  # le service s'il ne tourne pas déjà (sauf `start: false`).
  #
  #     - service-enable:
  #         name: nginx
  #         start: true        # défaut
  class ServiceEnable < ServicePrimitive
    def name : String
      "service-enable"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      svc = required_string(params, "name")
      start = bool(params, "start", default: true)

      already_enabled = enabled?(shell, svc)
      is_running = running?(shell, svc)
      need_enable = !already_enabled
      need_start = start && !is_running

      if !need_enable && !need_start
        return StepResult.skipped("#{svc} déjà activé#{start ? " et démarré" : ""}")
      end

      actions = [] of String
      actions << "enable" if need_enable
      actions << "start" if need_start
      msg = "#{svc} : #{actions.join(" + ")}"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      shell.exec("sysrc #{Process.quote("#{svc}_enable=YES")}") if need_enable
      shell.exec("service #{Process.quote(svc)} start") if need_start
      StepResult.applied(msg)
    end
  end

  # Primitive `service-disable` : `sysrc <svc>_enable=NO` puis arrête le
  # service s'il tourne (sauf `stop: false`).
  #
  #     - service-disable:
  #         name: sendmail
  #         stop: true         # défaut
  class ServiceDisable < ServicePrimitive
    def name : String
      "service-disable"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      svc = required_string(params, "name")
      stop = bool(params, "stop", default: true)

      is_enabled = enabled?(shell, svc)
      is_running = running?(shell, svc)
      need_disable = is_enabled
      need_stop = stop && is_running

      if !need_disable && !need_stop
        return StepResult.skipped("#{svc} déjà désactivé#{stop ? " et arrêté" : ""}")
      end

      actions = [] of String
      actions << "disable" if need_disable
      actions << "stop" if need_stop
      msg = "#{svc} : #{actions.join(" + ")}"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      shell.exec("sysrc #{Process.quote("#{svc}_enable=NO")}") if need_disable
      shell.exec("service #{Process.quote(svc)} stop") if need_stop
      StepResult.applied(msg)
    end
  end

  # Primitive `service-reload` : `service <svc> reload` — recharge la conf
  # d'un service SANS couper les sessions en cours (≠ restart). Usage type :
  # après une recette qui modifie sshd_config / nginx.conf. Skip si le
  # service n'est pas démarré (rien à recharger).
  #
  #     - service-reload:
  #         name: sshd
  class ServiceReload < ServicePrimitive
    def name : String
      "service-reload"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      svc = required_string(params, "name")
      unless running?(shell, svc)
        return StepResult.skipped("#{svc} non démarré → rien à recharger")
      end
      return StepResult.applied("#{svc} : reload (dry-run)") if dry_run
      shell.exec("service #{Process.quote(svc)} reload")
      StepResult.applied("#{svc} : reload")
    end
  end

  Primitive.register(ServiceEnable.new)
  Primitive.register(ServiceDisable.new)
  Primitive.register(ServiceReload.new)
end
