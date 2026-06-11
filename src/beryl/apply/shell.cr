require "ssh"

module Beryl::Apply
  # Abstraction de l'exécution de commandes distantes pour les
  # primitives. Découple la logique d'idempotence du transport SSH
  # réel, ce qui permet de tester les primitives sans serveur via un
  # `FakeShell` (même esprit que `FakeOvhTransport` côté providers).
  #
  # Les primitives ne connaissent que cette interface : `exec` (lecture
  # d'état + action) et `write_file`. La signature de retour est
  # `SSH::Result` pour rester homogène avec le shard `ssh`.
  abstract class Shell
    abstract def exec(command : String, raise_on_error : Bool = true) : SSH::Result
    abstract def write_file(remote_path : String, content : String, mode : String? = nil) : Nil
  end

  # Implémentation réelle : délègue à une `SSH::Connection`.
  class SshShell < Shell
    def initialize(@conn : SSH::Connection)
    end

    def exec(command : String, raise_on_error : Bool = true) : SSH::Result
      @conn.exec(command, raise_on_error: raise_on_error)
    end

    def write_file(remote_path : String, content : String, mode : String? = nil) : Nil
      @conn.write_file(remote_path, content, mode: mode)
    end
  end

  # Décorateur d'escalade : enrobe un `Shell` pour exécuter chaque commande
  # via `sudo` (NOPASSWD attendu). Utilisé quand beryl se connecte comme un
  # user sudo-capable plutôt que root (root SSH coupé sur les hôtes durcis).
  # Les écritures passent par un temp possédé par le user puis un `sudo
  # install` (root) — l'écriture SFTP directe ne pouvant pas escalader.
  class SudoShell < Shell
    def initialize(@inner : Shell)
    end

    def exec(command : String, raise_on_error : Bool = true) : SSH::Result
      @inner.exec("sudo sh -c #{Process.quote(command)}", raise_on_error: raise_on_error)
    end

    def write_file(remote_path : String, content : String, mode : String? = nil) : Nil
      tmp = @inner.exec("mktemp").stdout.strip
      @inner.write_file(tmp, content)
      @inner.exec("sudo install -m #{Process.quote(mode || "0644")} #{Process.quote(tmp)} #{Process.quote(remote_path)}")
      @inner.exec("rm -f #{Process.quote(tmp)}", raise_on_error: false)
    end
  end
end
