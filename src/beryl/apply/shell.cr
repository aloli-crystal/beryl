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
end
